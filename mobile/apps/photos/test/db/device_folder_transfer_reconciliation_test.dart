import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path_provider_platform_interface/path_provider_platform_interface.dart";
import "package:photos/db/files_db.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform previousPathProvider;

  setUpAll(() async {
    previousPathProvider = PathProviderPlatform.instance;
    tempDir = await Directory.systemTemp.createTemp(
      "device_folder_transfer_reconciliation_test_",
    );
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  setUp(() => FilesDB.instance.clearTable());

  tearDownAll(() async {
    final db = await FilesDB.instance.sqliteAsyncDB;
    await db.close();
    PathProviderPlatform.instance = previousPathProvider;
    await tempDir.delete(recursive: true);
  });

  test(
    "keeps a pending same-volume move available for destination backup",
    () async {
      final db = await FilesDB.instance.sqliteAsyncDB;
      await db.execute("INSERT INTO device_files (id, path_id) VALUES (?, ?)", [
        "42",
        "source",
      ]);
      await db.execute("INSERT INTO device_files (id, path_id) VALUES (?, ?)", [
        "42",
        "destination",
      ]);
      await db.execute(
        """
        INSERT INTO files (
          local_id,
          uploaded_file_id,
          collection_id,
          title,
          modification_time,
          creation_time
        ) VALUES (?, ?, ?, ?, ?, ?)
        """,
        ["42", -1, 101, "image.jpg", "1", "1"],
      );

      await FilesDB.instance.reconcileRemovedDeviceFolderMappings(
        mappingsToRemove: {
          "source": {"42"},
        },
        pendingMappingsToRemove: {
          "source": {"42"},
        },
        automaticBackupCollectionIDsByPath: {"source": 101},
        pendingMoves: [
          const PendingDeviceFolderMove(
            sourceCollectionID: 101,
            destinationFolderName: "Destination",
            localIDs: {"42"},
          ),
        ],
      );

      final files = await db.getAll(
        "SELECT collection_id, device_folder FROM files WHERE local_id = ?",
        ["42"],
      );
      final mappings = await db.getAll(
        "SELECT path_id FROM device_files WHERE id = ?",
        ["42"],
      );

      expect(files, [
        {"collection_id": null, "device_folder": "Destination"},
      ]);
      expect(mappings, [
        {"path_id": "destination"},
      ]);
    },
  );
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.documentsPath);

  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}
