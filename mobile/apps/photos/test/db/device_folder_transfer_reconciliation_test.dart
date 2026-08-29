import "dart:io";

import "package:ente_photos_platform/ente_photos_platform.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path_provider_platform_interface/path_provider_platform_interface.dart";
import "package:photos/db/files_db.dart";
import "package:photos/services/device_folder_transfer_coordinator.dart";
import "package:sqflite_common_ffi/sqflite_ffi.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform previousPathProvider;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
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
    "same-volume moves preserve file rows and replace folder membership",
    () async {
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
    },
  );

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

  test("moves that change a local ID are rejected", () async {
    await expectLater(
      DeviceFolderTransferCoordinator.reconcileDeviceFolderTransfer(
        DeviceFolderTransferOperation.move,
        sourcePathID: "source",
        targetPathID: "destination",
        destinations: const {"42": "99"},
      ),
      throwsA(isA<StateError>()),
    );
  });
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.documentsPath);

  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}
