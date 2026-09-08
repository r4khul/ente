import 'package:collection/collection.dart';
import 'package:ente_photos_platform/ente_photos_platform.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/db/device_files_db.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/events/local_photos_updated_event.dart';
import 'package:photos/models/device_collection.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/module/upload/service/file_uploader.dart';
import 'package:photos/services/sync/local_sync_service.dart';

class DeviceFolderTransferCoordinator {
  DeviceFolderTransferCoordinator._();

  static final instance = DeviceFolderTransferCoordinator._();

  final _logger = Logger('DeviceFolderTransferCoordinator');
  final _client = DeviceFolderTransferClient();

  Future<DeviceFolderTransferResult> transfer({
    required DeviceFolderTransferRequest request,
    required DeviceCollection source,
    required DeviceCollection destination,
  }) async {
    DeviceFolderTransferResult? deviceResult;
    try {
      return await LocalSyncService.instance.getLock().synchronized(() async {
        final folders = await FilesDB.instance.getDeviceCollections();
        final currentSource = folders.firstWhereOrNull(
          (folder) => folder.id == source.id,
        );
        final currentDestination = folders.firstWhereOrNull(
          (folder) => folder.id == destination.id,
        );
        if (currentSource == null || currentDestination == null) {
          throw StateError('The selected device folder is no longer available');
        }
        if (source.shouldBackup != currentSource.shouldBackup ||
            destination.shouldBackup != currentDestination.shouldBackup) {
          throw StateError('The device folder backup state changed');
        }
        if (request.operation == DeviceFolderTransferOperation.move) {
          await _ensureStableMove(request.sourceLocalIDs, currentSource);
        }

        final result = await _client.transfer(request);
        deviceResult = result;
        if (result.destinations.isEmpty) return result;
        if (request.operation == DeviceFolderTransferOperation.move &&
            result.destinations.entries.any(
              (entry) => entry.key != entry.value,
            )) {
          _logger.warning('Native move unexpectedly changed a local ID');
          return result.copyWith(localReconciliationFailed: true);
        }
        try {
          await reconcileDeviceFolderTransfer(
            request.operation,
            sourcePathID: currentSource.id,
            targetPathID: currentDestination.id,
            destinations: result.destinations,
          );
        } catch (error, stackTrace) {
          _logger.warning(
            'Could not reconcile transferred files',
            error,
            stackTrace,
          );
          return result.copyWith(localReconciliationFailed: true);
        }
        return result;
      });
    } finally {
      final result = deviceResult;
      if (result != null && !result.wasCancelled) {
        try {
          await LocalSyncService.instance.syncAll();
        } catch (error, stackTrace) {
          _logger.warning(
            'Could not refresh local state after device-folder transfer',
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
    }
  }

  Future<void> _ensureStableMove(
    Iterable<String> localIDs,
    DeviceCollection source,
  ) async {
    final ids = localIDs.toSet();
    final pendingUploads = FileUploader.instance.allBackups;
    if (ids.isEmpty || ids.any(pendingUploads.containsKey)) {
      throw StateError('Finish backup before moving these files');
    }
    if (!source.shouldBackup) return;

    final sourceCollectionID = source.collectionID;
    if (sourceCollectionID == null || sourceCollectionID == -1) {
      throw StateError('The source backup collection is unavailable');
    }
    final uploaded = await FilesDB.instance.getUploadedLocalIDs(
      ids,
      collectionID: sourceCollectionID,
    );
    if (uploaded.length != ids.length) {
      throw StateError('Finish backup before moving these files');
    }
  }

  static Future<void> reconcileDeviceFolderTransfer(
    DeviceFolderTransferOperation operation, {
    required String sourcePathID,
    required String targetPathID,
    required Map<String, String> destinations,
  }) async {
    final db = await FilesDB.instance.sqliteAsyncDB;
    await db.writeTransaction((tx) async {
      for (final entries in destinations.entries.slices(400)) {
        if (operation == DeviceFolderTransferOperation.move) {
          if (entries.any((entry) => entry.key != entry.value)) {
            throw StateError('A device move changed a local ID');
          }
          await tx.executeBatch(
            'DELETE FROM ${FilesDB.deviceFilesTable} '
            'WHERE id = ? AND path_id = ?;',
            entries.map((entry) => [entry.key, sourcePathID]).toList(),
          );
        }
        await tx.executeBatch(
          'INSERT OR IGNORE INTO ${FilesDB.deviceFilesTable} '
          '(id, path_id) VALUES (?, ?);',
          entries.map((entry) => [entry.value, targetPathID]).toList(),
        );
      }
    });
  }
}
