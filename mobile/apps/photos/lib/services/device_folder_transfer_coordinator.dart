import 'dart:io';

import 'package:collection/collection.dart';
import 'package:ente_photos_platform/ente_photos_platform.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/core/user_config.dart';
import 'package:photos/db/device_files_db.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/events/local_photos_updated_event.dart';
import 'package:photos/models/device_collection.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/services/collections_service.dart';
import 'package:photos/services/sync/local_sync_service.dart';
import 'package:photos/services/sync/remote_sync_service.dart';
import 'package:uuid/uuid.dart';

class DeviceFolderTransferCoordinator {
  DeviceFolderTransferCoordinator._();

  static final instance = DeviceFolderTransferCoordinator._();

  final _logger = Logger('DeviceFolderTransferCoordinator');
  final _client = DeviceFolderTransferClient();

  Future<DeviceFolderTransferResult> transfer({
    required DeviceFolderTransferRequest request,
    required DeviceCollection source,
    required DeviceCollection destination,
    int? cloudMoveSourceCollectionID,
  }) async {
    final result = await LocalSyncService.instance.getLock().synchronized(
      () => _transfer(
        request: request,
        source: source,
        destination: destination,
        cloudMoveSourceCollectionID: cloudMoveSourceCollectionID,
      ),
    );
    if (result.successLocalIDs.isNotEmpty) {
      try {
        await LocalSyncService.instance.syncAll();
      } catch (error, stackTrace) {
        _logger.warning(
          'Could not refresh local state after device-folder ${request.operation.name}',
          error,
          stackTrace,
        );
      }
      if (request.operation == DeviceFolderTransferOperation.move) {
        Bus.instance.fire(
          LocalPhotosUpdatedEvent(
            const <EnteFile>[],
            source: 'deviceFolderTransfer',
          ),
        );
      }
    }
    return result;
  }

  Future<DeviceFolderTransferResult> _transfer({
    required DeviceFolderTransferRequest request,
    required DeviceCollection source,
    required DeviceCollection destination,
    required int? cloudMoveSourceCollectionID,
  }) async {
    final (currentSource, currentDestination) = await _currentFolders(
      source,
      destination,
    );
    _validateFolderState(
      source: source,
      destination: destination,
      currentSource: currentSource,
      currentDestination: currentDestination,
      cloudMoveSourceCollectionID: cloudMoveSourceCollectionID,
    );

    final transferID = const Uuid().v4();
    final ownerID = Configuration.instance.getUserIDV2();
    final result = await _client.transfer(
      request.copyWith(
        transferID: transferID,
        recoveryContext: {
          'operation': request.operation.name,
          'sourceFolderID': currentSource.id,
          'targetFolderID': currentDestination.id,
          'ownerID': ownerID,
          if (cloudMoveSourceCollectionID != null)
            'cloudMoveSourceCollectionID': cloudMoveSourceCollectionID,
        },
      ),
    );

    await _completeTransfer(
      transferID: transferID,
      operation: request.operation,
      source: currentSource,
      destination: currentDestination,
      result: result,
      cloudMoveSourceCollectionID: cloudMoveSourceCollectionID,
      cloudMoveStarted: false,
      cloudMoveCompleted: false,
    );
    return result;
  }

  Future<void> recoverPendingTransfers() async {
    if (!Platform.isAndroid) return;
    late final List<DeviceFolderTransferRecovery> recoveries;
    try {
      recoveries = await _client.pendingRecoveries();
    } catch (error, stackTrace) {
      _logger.warning(
        'Could not read device-folder transfer recovery records',
        error,
        stackTrace,
      );
      return;
    }
    for (final recovery in recoveries) {
      try {
        if (recovery.ownerID != Configuration.instance.getUserIDV2()) {
          continue;
        }
        final collections = await FilesDB.instance.getDeviceCollections();
        final source = collections
            .where((collection) => collection.id == recovery.sourceFolderID)
            .firstOrNull;
        final destination = collections
            .where((collection) => collection.id == recovery.targetFolderID)
            .firstOrNull;
        if (source == null || destination == null) continue;
        await LocalSyncService.instance.getLock().synchronized(
          () => _completeTransfer(
            transferID: recovery.transferID,
            operation: recovery.operation,
            source: source,
            destination: destination,
            result: recovery.result,
            cloudMoveSourceCollectionID: recovery.cloudMoveSourceCollectionID,
            cloudMoveStarted: recovery.cloudMoveStarted,
            cloudMoveCompleted: recovery.cloudMoveCompleted,
          ),
        );
      } catch (error, stackTrace) {
        _logger.warning(
          'Could not recover device-folder move ${recovery.transferID}',
          error,
          stackTrace,
        );
      }
    }
  }

  Future<void> _completeTransfer({
    required String transferID,
    required DeviceFolderTransferOperation operation,
    required DeviceCollection source,
    required DeviceCollection destination,
    required DeviceFolderTransferResult result,
    required int? cloudMoveSourceCollectionID,
    required bool cloudMoveStarted,
    required bool cloudMoveCompleted,
  }) async {
    final destinations = result.destinations;
    if (destinations.isEmpty) {
      if (!result.requiresRecovery) {
        await _finish(transferID);
      }
      return;
    }

    if (operation == DeviceFolderTransferOperation.move) {
      await FilesDB.instance.rebindDeviceFolderMove(
        sourcePathID: source.id,
        targetPathID: destination.id,
        destinationLocalIDs: {
          for (final entry in destinations.entries)
            entry.key: entry.value.localID,
        },
      );
    }

    if (!result.requiresRecovery &&
        operation == DeviceFolderTransferOperation.move &&
        cloudMoveSourceCollectionID != null &&
        !cloudMoveCompleted) {
      if (cloudMoveStarted) {
        await RemoteSyncService.instance.sync(silently: true);
      }
      final files = await FilesDB.instance.getUploadedFilesForLocalIDs(
        destinations.values.map((destination) => destination.localID),
        collectionID: cloudMoveSourceCollectionID,
      );
      await _client.markCloudMoveStarted(transferID);
      await _moveFilesInEnte(files, destination, cloudMoveSourceCollectionID);
      await _client.markCloudMoveCompleted(transferID);
    }
    if (!result.requiresRecovery) {
      await _finish(transferID);
    }
  }

  Future<(DeviceCollection, DeviceCollection)> _currentFolders(
    DeviceCollection source,
    DeviceCollection destination,
  ) async {
    final folders = await FilesDB.instance.getDeviceCollections();
    final currentSource = folders
        .where((folder) => folder.id == source.id)
        .firstOrNull;
    final currentDestination = folders
        .where((folder) => folder.id == destination.id)
        .firstOrNull;
    if (currentSource == null || currentDestination == null) {
      throw StateError('The selected device folder is no longer available');
    }
    return (currentSource, currentDestination);
  }

  void _validateFolderState({
    required DeviceCollection source,
    required DeviceCollection destination,
    required DeviceCollection currentSource,
    required DeviceCollection currentDestination,
    required int? cloudMoveSourceCollectionID,
  }) {
    if (source.shouldBackup != currentSource.shouldBackup ||
        destination.shouldBackup != currentDestination.shouldBackup) {
      throw StateError('The device folder backup state changed');
    }
    if (cloudMoveSourceCollectionID != null &&
        (!currentSource.shouldBackup ||
            currentSource.collectionID != cloudMoveSourceCollectionID)) {
      throw StateError('The source backup collection changed');
    }
  }

  Future<void> _moveFilesInEnte(
    List<EnteFile> files,
    DeviceCollection destination,
    int sourceCollectionID,
  ) async {
    if (files.isEmpty) return;
    final target = await _ensureBackupCollection(destination);
    final movableFiles = files
        .where((file) => file.collectionID == sourceCollectionID)
        .map((file) => file.copyWith())
        .toList();
    if (movableFiles.isEmpty || sourceCollectionID == target) return;
    await CollectionsService.instance.move(
      movableFiles,
      toCollectionID: target,
      fromCollectionID: sourceCollectionID,
    );
  }

  Future<int> _ensureBackupCollection(DeviceCollection destination) async {
    if (destination.hasCollectionID()) return destination.collectionID!;
    final collection = await CollectionsService.instance.getOrCreateForPath(
      destination.name,
    );
    await FilesDB.instance.updateDeviceCollection(
      destination.id,
      collection.id,
    );
    return collection.id;
  }

  Future<void> _finish(String transferID) =>
      _client.acknowledgeRecovery(transferID);
}
