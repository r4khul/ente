import 'package:collection/collection.dart';
import 'package:ente_photos_platform/ente_photos_platform.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/db/device_files_db.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/events/local_photos_updated_event.dart';
import 'package:photos/models/device_collection.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/services/collections_service.dart';
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
    int? cloudMoveSourceCollectionID,
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
            destination.shouldBackup != currentDestination.shouldBackup ||
            (cloudMoveSourceCollectionID != null &&
                (!currentSource.shouldBackup ||
                    currentSource.collectionID !=
                        cloudMoveSourceCollectionID))) {
          throw StateError('The device folder backup state changed');
        }
        final expectedCloudMoveIDs = <String, Set<int>>{};
        if (cloudMoveSourceCollectionID != null) {
          for (final file in await FilesDB.instance.getUploadedFilesForLocalIDs(
            request.sourceLocalIDs,
            collectionID: cloudMoveSourceCollectionID,
          )) {
            final localID = file.localID;
            final uploadedID = file.uploadedFileID;
            if (localID != null && uploadedID != null) {
              expectedCloudMoveIDs
                  .putIfAbsent(localID, () => {})
                  .add(uploadedID);
            }
          }
          if (expectedCloudMoveIDs.isEmpty) {
            throw StateError('The source backup collection changed');
          }
        }

        // Native MediaStore changes are deliberately not journaled. If the app
        // stops before this transaction, the next syncAll reconciles them just
        // like a move made in the system Files app.
        final result = await _client.transfer(request);
        deviceResult = result;
        if (result.destinations.isEmpty) return result;

        await reconcileDeviceFolderTransfer(
          request.operation,
          sourcePathID: currentSource.id,
          targetPathID: currentDestination.id,
          destinations: result.destinationLocalIDs,
        );
        if (request.operation == DeviceFolderTransferOperation.move &&
            cloudMoveSourceCollectionID != null) {
          final expectedIDs = result.successLocalIDs
              .expand(
                (localID) => expectedCloudMoveIDs[localID] ?? const <int>{},
              )
              .toSet();
          final files = await FilesDB.instance.getUploadedFilesForLocalIDs(
            result.destinations.values.map(
              (destination) => destination.localID,
            ),
            collectionID: cloudMoveSourceCollectionID,
          );
          final actualIDs = files
              .map((file) => file.uploadedFileID)
              .whereType<int>()
              .toSet();
          if (!actualIDs.containsAll(expectedIDs)) {
            throw StateError('Could not resolve files for the Ente move');
          }
          await _moveFilesInEnte(
            files
                .where((file) => expectedIDs.contains(file.uploadedFileID))
                .toList(),
            currentDestination,
            cloudMoveSourceCollectionID,
          );
        }
        return result;
      });
    } finally {
      final result = deviceResult;
      if (result != null && result.destinations.isNotEmpty) {
        // A cloud-move error still propagates, but the completed MediaStore
        // transfer must be reflected locally before the caller handles it.
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
          await tx.executeBatch(
            'UPDATE ${FilesDB.filesTable} SET ${FilesDB.columnCollectionID} = NULL, '
            '${FilesDB.columnAutoBackupPathID} = NULL WHERE ${FilesDB.columnLocalID} = ? '
            'AND (${FilesDB.columnUploadedFileID} IS NULL OR ${FilesDB.columnUploadedFileID} = -1) '
            'AND ${FilesDB.columnAutoBackupPathID} = ?;',
            entries.map((entry) => [entry.key, sourcePathID]).toList(),
          );
          final changedIDs = entries
              .where((entry) => entry.key != entry.value)
              .toList();
          if (changedIDs.isNotEmpty) {
            await tx.executeBatch(
              'UPDATE OR IGNORE ${FilesDB.filesTable} SET ${FilesDB.columnLocalID} = ? '
              'WHERE ${FilesDB.columnLocalID} = ?;',
              changedIDs.map((entry) => [entry.value, entry.key]).toList(),
            );
            await tx.executeBatch(
              'DELETE FROM ${FilesDB.filesTable} WHERE ${FilesDB.columnLocalID} = ? AND EXISTS ('
              'SELECT 1 FROM ${FilesDB.filesTable} AS destination '
              'WHERE destination.${FilesDB.columnLocalID} = ? '
              'AND COALESCE(destination.${FilesDB.columnUploadedFileID}, -1) = '
              'COALESCE(${FilesDB.filesTable}.${FilesDB.columnUploadedFileID}, -1) '
              'AND COALESCE(destination.${FilesDB.columnCollectionID}, -1) = '
              'COALESCE(${FilesDB.filesTable}.${FilesDB.columnCollectionID}, -1));',
              changedIDs.map((entry) => [entry.key, entry.value]).toList(),
            );
          }
          await tx.executeBatch(
            'DELETE FROM ${FilesDB.deviceFilesTable} WHERE id = ? AND path_id = ?;',
            entries.map((entry) => [entry.key, sourcePathID]).toList(),
          );
        }
        await tx.executeBatch(
          'INSERT OR IGNORE INTO ${FilesDB.deviceFilesTable} (id, path_id) VALUES (?, ?);',
          entries.map((entry) => [entry.value, targetPathID]).toList(),
        );
      }
    });
  }

  Future<void> _moveFilesInEnte(
    List<EnteFile> files,
    DeviceCollection destination,
    int sourceCollectionID,
  ) async {
    if (files.isEmpty) return;
    final target = destination.hasCollectionID()
        ? destination.collectionID!
        : (await CollectionsService.instance.getOrCreateForPath(
            destination.name,
          )).id;
    if (!destination.hasCollectionID()) {
      await FilesDB.instance.updateDeviceCollection(destination.id, target);
    }
    final movable = files
        .where((file) => file.collectionID == sourceCollectionID)
        .toList();
    if (movable.isNotEmpty && target != sourceCollectionID) {
      await CollectionsService.instance.move(
        movable.map((file) => file.copyWith()).toList(),
        toCollectionID: target,
        fromCollectionID: sourceCollectionID,
      );
    }
  }
}
