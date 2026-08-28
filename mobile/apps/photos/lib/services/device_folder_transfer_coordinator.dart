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
import 'package:uuid/uuid.dart';

class DeviceFolderTransferCloudMove {
  const DeviceFolderTransferCloudMove({
    required this.sourceCollectionID,
    required this.sourceLocalIDs,
    this.sourceUploadedFileIDs = const {},
  });

  final int sourceCollectionID;
  final Set<String> sourceLocalIDs;
  final Map<String, List<int>> sourceUploadedFileIDs;
}

class DeviceFolderTransferCoordinator {
  DeviceFolderTransferCoordinator._();

  static final instance = DeviceFolderTransferCoordinator._();

  final _logger = Logger('DeviceFolderTransferCoordinator');
  final _client = DeviceFolderTransferClient();

  Future<DeviceFolderTransferResult> transfer({
    required DeviceFolderTransferRequest request,
    required DeviceCollection source,
    required DeviceCollection destination,
    required DeviceFolderTransferCloudMove? cloudMove,
    Map<String, int> sourceRecordIDs = const {},
  }) async {
    final result = await LocalSyncService.instance.getLock().synchronized(
      () => _transfer(
        request: request,
        source: source,
        destination: destination,
        sourceRecordIDs: sourceRecordIDs,
        cloudMove: cloudMove,
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
    required Map<String, int> sourceRecordIDs,
    required DeviceFolderTransferCloudMove? cloudMove,
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
      cloudMove: cloudMove,
    );

    final isMove = request.operation == DeviceFolderTransferOperation.move;
    if (isMove &&
        !sourceRecordIDs.keys.toSet().containsAll(request.sourceLocalIDs)) {
      throw StateError('Could not identify every selected device file');
    }
    final resolvedCloudMove = await _resolveCloudMove(cloudMove);
    final transferID = isMove ? const Uuid().v4() : null;
    final ownerID = Configuration.instance.getUserIDV2();
    final result = await _client.transfer(
      request.copyWith(
        transferID: transferID,
        recoveryContext: transferID == null
            ? null
            : {
                'sourceFolderID': currentSource.id,
                'targetFolderID': currentDestination.id,
                'ownerID': ownerID,
                'sourceLocalIDs': request.sourceLocalIDs,
                'sourceRecordIDs': sourceRecordIDs,
                if (resolvedCloudMove != null) ...{
                  'cloudMoveSourceCollectionID':
                      resolvedCloudMove.sourceCollectionID,
                  'cloudMoveSourceLocalIDs': resolvedCloudMove.sourceLocalIDs
                      .toList(),
                  'cloudMoveSourceUploadedFileIDs':
                      resolvedCloudMove.sourceUploadedFileIDs,
                },
              },
      ),
    );
    if (transferID == null) return result;

    await _completeMove(
      transferID: transferID,
      source: currentSource,
      destination: currentDestination,
      result: result,
      selectedIDs: request.sourceLocalIDs.toSet(),
      sourceRecordIDs: sourceRecordIDs,
      cloudMove: resolvedCloudMove,
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
        final cloudMove = recovery.hasCloudMove
            ? DeviceFolderTransferCloudMove(
                sourceCollectionID: recovery.cloudMoveSourceCollectionID!,
                sourceLocalIDs: recovery.cloudMoveSourceLocalIDs,
                sourceUploadedFileIDs: recovery.cloudMoveSourceUploadedFileIDs,
              )
            : null;
        await LocalSyncService.instance.getLock().synchronized(
          () => _completeMove(
            transferID: recovery.transferID,
            source: source,
            destination: destination,
            result: recovery.result,
            selectedIDs: recovery.sourceLocalIDs,
            sourceRecordIDs: recovery.sourceRecordIDs,
            cloudMove: cloudMove,
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

  Future<void> _completeMove({
    required String transferID,
    required DeviceCollection source,
    required DeviceCollection destination,
    required DeviceFolderTransferResult result,
    required Set<String> selectedIDs,
    required Map<String, int> sourceRecordIDs,
    required DeviceFolderTransferCloudMove? cloudMove,
    required bool cloudMoveCompleted,
  }) async {
    final destinations =
        Map<String, DeviceFolderTransferDestination>.fromEntries(
          result.destinations.entries.where(
            (entry) => selectedIDs.contains(entry.key),
          ),
        );
    if (destinations.isEmpty) {
      if (!result.requiresRecovery) {
        await _finish(transferID);
      }
      return;
    }
    if (!sourceRecordIDs.keys.toSet().containsAll(destinations.keys)) {
      throw StateError('Could not identify every moved device file');
    }
    final cloudMovedIDs = cloudMove == null
        ? const <String>{}
        : destinations.keys.where(cloudMove.sourceLocalIDs.contains).toSet();
    if (cloudMove != null &&
        !cloudMove.sourceUploadedFileIDs.keys.toSet().containsAll(
          cloudMovedIDs,
        )) {
      throw StateError('Could not identify every cloud-moved device file');
    }

    if (cloudMove != null && !cloudMoveCompleted) {
      final files = await FilesDB.instance.getUploadedFilesForLocalIDs(
        destinations.keys.where(cloudMove.sourceLocalIDs.contains),
        collectionID: cloudMove.sourceCollectionID,
      );
      await _moveFilesInEnte(files, destination, cloudMove.sourceCollectionID);
      await _client.markCloudMoveCompleted(transferID);
    }
    await FilesDB.instance.reconcileDeviceFolderMove(
      sourcePathID: source.id,
      targetPathID: destination.id,
      targetFolderName: destination.name,
      destinations: {
        for (final entry in destinations.entries)
          entry.key: (
            localID: entry.value.localID,
            displayName: entry.value.displayName,
          ),
      },
      sourceRecordIDs: sourceRecordIDs,
      cloudMovedSourceUploadedFileIDs: {
        for (final localID in cloudMovedIDs)
          localID: cloudMove!.sourceUploadedFileIDs[localID]!,
      },
    );
    await _finish(transferID);
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

  Future<DeviceFolderTransferCloudMove?> _resolveCloudMove(
    DeviceFolderTransferCloudMove? cloudMove,
  ) async {
    if (cloudMove == null) return null;
    final files = await FilesDB.instance.getUploadedFilesForLocalIDs(
      cloudMove.sourceLocalIDs,
      collectionID: cloudMove.sourceCollectionID,
    );
    final sourceUploadedFileIDs = <String, List<int>>{};
    for (final file in files) {
      if (file.localID == null || file.uploadedFileID == null) continue;
      sourceUploadedFileIDs
          .putIfAbsent(file.localID!, () => <int>[])
          .add(file.uploadedFileID!);
    }
    if (!sourceUploadedFileIDs.keys.toSet().containsAll(
      cloudMove.sourceLocalIDs,
    )) {
      throw StateError('Could not identify every cloud-moved device file');
    }
    return DeviceFolderTransferCloudMove(
      sourceCollectionID: cloudMove.sourceCollectionID,
      sourceLocalIDs: cloudMove.sourceLocalIDs,
      sourceUploadedFileIDs: sourceUploadedFileIDs,
    );
  }

  void _validateFolderState({
    required DeviceCollection source,
    required DeviceCollection destination,
    required DeviceCollection currentSource,
    required DeviceCollection currentDestination,
    required DeviceFolderTransferCloudMove? cloudMove,
  }) {
    if (source.shouldBackup != currentSource.shouldBackup ||
        destination.shouldBackup != currentDestination.shouldBackup) {
      throw StateError('The device folder backup state changed');
    }
    if (cloudMove != null &&
        (!currentSource.shouldBackup ||
            currentSource.collectionID != cloudMove.sourceCollectionID)) {
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
