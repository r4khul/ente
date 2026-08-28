import "dart:io";

import "package:ente_photos_platform/ente_photos_platform.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path_provider_platform_interface/path_provider_platform_interface.dart";
import "package:photos/db/files_db.dart";
import "package:photos/services/device_folder_transfer_coordinator.dart";

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
    "rebinds every representation from the canonical local-ID mapping",
    () async {
      final db = await FilesDB.instance.sqliteAsyncDB;
      await db.execute("INSERT INTO device_files (id, path_id) VALUES (?, ?)", [
        "42",
        "source",
      ]);
      for (final row in <List<Object?>>[
        ["42", -1, 101, "source", "automatic.jpg", "Source"],
        ["42", -1, 505, null, "manual-pending.jpg", "Manual album"],
        ["42", 77, 202, null, "linked-one.jpg", "Manual album"],
        ["42", 77, 303, null, "linked-two.jpg", "Manual album"],
        ["42", 88, 404, null, "another-link.jpg", "Another album"],
      ]) {
        await db.execute(
          """
          INSERT INTO files (
            local_id, uploaded_file_id, collection_id, auto_backup_path_id,
            title, device_folder,
            modification_time, creation_time
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
          [...row, "1", "1"],
        );
      }

      await DeviceFolderTransferCoordinator.reconcileDeviceFolderTransfer(
        DeviceFolderTransferOperation.move,
        sourcePathID: "source",
        targetPathID: "destination",
        destinations: const {"42": "99"},
      );

      expect(
        await db.getAll("""
          SELECT local_id, uploaded_file_id, collection_id, auto_backup_path_id,
          title, device_folder
          FROM files ORDER BY collection_id
          """),
        [
          {
            "local_id": "99",
            "uploaded_file_id": -1,
            "collection_id": null,
            "auto_backup_path_id": null,
            "title": "automatic.jpg",
            "device_folder": "Source",
          },
          {
            "local_id": "99",
            "uploaded_file_id": 77,
            "collection_id": 202,
            "auto_backup_path_id": null,
            "title": "linked-one.jpg",
            "device_folder": "Manual album",
          },
          {
            "local_id": "99",
            "uploaded_file_id": 77,
            "collection_id": 303,
            "auto_backup_path_id": null,
            "title": "linked-two.jpg",
            "device_folder": "Manual album",
          },
          {
            "local_id": "99",
            "uploaded_file_id": 88,
            "collection_id": 404,
            "auto_backup_path_id": null,
            "title": "another-link.jpg",
            "device_folder": "Another album",
          },
          {
            "local_id": "99",
            "uploaded_file_id": -1,
            "collection_id": 505,
            "auto_backup_path_id": null,
            "title": "manual-pending.jpg",
            "device_folder": "Manual album",
          },
        ],
      );
      expect(await db.getAll("SELECT id, path_id FROM device_files"), [
        {"id": "99", "path_id": "destination"},
      ]);
    },
  );

  test("same-volume moves preserve the local ID", () async {
    final db = await FilesDB.instance.sqliteAsyncDB;
    await db.execute("INSERT INTO device_files (id, path_id) VALUES (?, ?)", [
      "42",
      "source",
    ]);
    await db.execute(
      """
      INSERT INTO files (
        local_id, uploaded_file_id, collection_id, title, modification_time,
        creation_time
      ) VALUES (?, ?, ?, ?, ?, ?)
      """,
      ["42", 77, 202, "linked.jpg", "1", "1"],
    );

    await DeviceFolderTransferCoordinator.reconcileDeviceFolderTransfer(
      DeviceFolderTransferOperation.move,
      sourcePathID: "source",
      targetPathID: "destination",
      destinations: const {"42": "42"},
    );

    expect(await db.getAll("SELECT local_id, collection_id FROM files"), [
      {"local_id": "42", "collection_id": 202},
    ]);
    expect(await db.getAll("SELECT id, path_id FROM device_files"), [
      {"id": "42", "path_id": "destination"},
    ]);
  });

  test("copies retain the source mapping and add the destination", () async {
    final db = await FilesDB.instance.sqliteAsyncDB;
    await db.execute("INSERT INTO device_files (id, path_id) VALUES (?, ?)", [
      "42",
      "source",
    ]);

    await DeviceFolderTransferCoordinator.reconcileDeviceFolderTransfer(
      DeviceFolderTransferOperation.copy,
      sourcePathID: "source",
      targetPathID: "destination",
      destinations: const {"42": "99"},
    );

    expect(await db.getAll("SELECT id, path_id FROM device_files"), [
      {"id": "42", "path_id": "source"},
      {"id": "99", "path_id": "destination"},
    ]);
  });

  test("is idempotent after a cross-volume rebind", () async {
    final db = await FilesDB.instance.sqliteAsyncDB;
    await db.execute("INSERT INTO device_files (id, path_id) VALUES (?, ?)", [
      "42",
      "source",
    ]);
    await db.execute(
      """
        INSERT INTO files (
          local_id, uploaded_file_id, collection_id, title, modification_time,
          creation_time
        ) VALUES (?, ?, ?, ?, ?, ?)
        """,
      ["42", 77, 202, "source.jpg", "1", "1"],
    );

    await DeviceFolderTransferCoordinator.reconcileDeviceFolderTransfer(
      DeviceFolderTransferOperation.move,
      sourcePathID: "source",
      targetPathID: "destination",
      destinations: const {"42": "99"},
    );
    await DeviceFolderTransferCoordinator.reconcileDeviceFolderTransfer(
      DeviceFolderTransferOperation.move,
      sourcePathID: "source",
      targetPathID: "destination",
      destinations: const {"42": "99"},
    );

    expect(await db.getAll("SELECT local_id, title FROM files"), [
      {"local_id": "99", "title": "source.jpg"},
    ]);
    expect(await db.getAll("SELECT id, path_id FROM device_files"), [
      {"id": "99", "path_id": "destination"},
    ]);
  });
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.documentsPath);

  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}
