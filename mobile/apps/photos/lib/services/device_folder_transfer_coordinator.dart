import 'dart:io';

import 'package:collection/collection.dart';
import 'package:ente_photos_platform/ente_photos_platform.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/user_config.dart';
import 'package:photos/db/device_files_db.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/models/device_collection.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/services/collections_service.dart';
import 'package:photos/services/sync/local_sync_service.dart';
import 'package:uuid/uuid.dart';

class DeviceFolderTransferCloudMove {
  const DeviceFolderTransferCloudMove({
    required this.sourceCollectionID,
    required this.sourceLocalIDs,
  });

  final int sourceCollectionID;
  final Set<String> sourceLocalIDs;
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
    required Set<String> uploadedSourceLocalIDs,
    required DeviceFolderTransferCloudMove? cloudMove,
  }) => LocalSyncService.instance.getLock().synchronized(
    () => _transfer(
      request: request,
      source: source,
      destination: destination,
      uploadedSourceLocalIDs: uploadedSourceLocalIDs,
      cloudMove: cloudMove,
    ),
  );

  Future<DeviceFolderTransferResult> _transfer({
    required DeviceFolderTransferRequest request,
    required DeviceCollection source,
    required DeviceCollection destination,
    required Set<String> uploadedSourceLocalIDs,
    required DeviceFolderTransferCloudMove? cloudMove,
  }) async {
    final ownerID = Configuration.instance.getUserIDV2();
    final isBackedUpMove =
        request.operation == DeviceFolderTransferOperation.move &&
        uploadedSourceLocalIDs.isNotEmpty;
    final transferID = isBackedUpMove ? const Uuid().v4() : null;
    final result = await _client.transfer(
      DeviceFolderTransferRequest(
        operation: request.operation,
        sourceFolderID: request.sourceFolderID,
        identityPolicy: request.identityPolicy,
        targetFolderID: request.targetFolderID,
        sourceLocalIDs: request.sourceLocalIDs,
        transferID: transferID,
        recoveryContext: transferID == null
            ? null
            : {
                'sourceFolderID': source.id,
                'targetFolderID': destination.id,
                'ownerID': ownerID,
                'sourceLocalIDs': uploadedSourceLocalIDs.toList(),
                if (cloudMove != null) ...{
                  'cloudMoveSourceCollectionID': cloudMove.sourceCollectionID,
                  'cloudMoveSourceLocalIDs': cloudMove.sourceLocalIDs.toList(),
                },
              },
      ),
    );
    if (transferID == null) return result;

    await _completeBackedUpMove(
      transferID: transferID,
      source: source,
      destination: destination,
      result: result,
      selectedIDs: uploadedSourceLocalIDs,
      cloudMove: cloudMove,
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
        final collections = await FilesDB.instance.getDeviceCollections();
        final source = collections
            .where((c) => c.id == recovery.sourceFolderID)
            .firstOrNull;
        final destination = collections
            .where((c) => c.id == recovery.targetFolderID)
            .firstOrNull;
        if (source == null || destination == null) continue;
        if (recovery.ownerID != Configuration.instance.getUserIDV2()) {
          continue;
        }
        final cloudMove = recovery.hasCloudMove
            ? DeviceFolderTransferCloudMove(
                sourceCollectionID: recovery.cloudMoveSourceCollectionID!,
                sourceLocalIDs: recovery.cloudMoveSourceLocalIDs,
              )
            : null;
        await LocalSyncService.instance.getLock().synchronized(
          () => _completeBackedUpMove(
            transferID: recovery.transferID,
            source: source,
            destination: destination,
            result: recovery.result,
            selectedIDs: recovery.sourceLocalIDs,
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

  Future<void> _completeBackedUpMove({
    required String transferID,
    required DeviceCollection source,
    required DeviceCollection destination,
    required DeviceFolderTransferResult result,
    required Set<String> selectedIDs,
    required DeviceFolderTransferCloudMove? cloudMove,
    required bool cloudMoveCompleted,
  }) async {
    final destinationIDs = Map<String, String>.fromEntries(
      result.destinationLocalIDs.entries.where(
        (entry) => selectedIDs.contains(entry.key),
      ),
    );
    if (destinationIDs.isEmpty) {
      await _finish(transferID);
      return;
    }

    if (cloudMove != null && !cloudMoveCompleted) {
      final files = await FilesDB.instance.getUploadedFilesForLocalIDs(
        destinationIDs.keys.where(cloudMove.sourceLocalIDs.contains),
        collectionID: cloudMove.sourceCollectionID,
      );
      await _moveFilesInEnte(files, destination, cloudMove.sourceCollectionID);
      await _client.markCloudMoveCompleted(transferID);
    }
    await FilesDB.instance.reconcileUploadedDeviceFolderMove(
      sourcePathID: source.id,
      targetPathID: destination.id,
      destinationLocalIDs: destinationIDs,
    );
    await _finish(transferID);
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

  Future<void> _finish(String transferID) async {
    await _client.acknowledgeRecovery(transferID);
  }
}
