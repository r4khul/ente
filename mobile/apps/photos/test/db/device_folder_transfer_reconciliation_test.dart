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
    "moves a pending row directly instead of deleting and rediscovering it",
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
        ["42", -1, 101, "image.jpg", "1", "1"],
      );
      final row = await db.get(
        "SELECT _id FROM files WHERE collection_id = ?",
        [101],
      );

      await FilesDB.instance.reconcileDeviceFolderMove(
        sourcePathID: "source",
        targetPathID: "destination",
        targetFolderName: "Destination",
        destinations: const {
          "42": (localID: "42", displayName: "image (1).jpg"),
        },
        sourceRecordIDs: {"42": row["_id"] as int},
        cloudMovedSourceUploadedFileIDs: const {},
      );

      expect(
        await db.getAll(
          "SELECT local_id, collection_id, title, device_folder FROM files",
        ),
        [
          {
            "local_id": "42",
            "collection_id": null,
            "title": "image (1).jpg",
            "device_folder": "Destination",
          },
        ],
      );
      expect(await db.getAll("SELECT id, path_id FROM device_files"), [
        {"id": "42", "path_id": "destination"},
      ]);
    },
  );

  test(
    "keeps the stored title when a legacy result has no display name",
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
        ["42", -1, 101, "image.jpg", "1", "1"],
      );
      final row = await db.get(
        "SELECT _id FROM files WHERE collection_id = ?",
        [101],
      );

      await FilesDB.instance.reconcileDeviceFolderMove(
        sourcePathID: "source",
        targetPathID: "destination",
        targetFolderName: "Destination",
        destinations: const {"42": (localID: "42", displayName: null)},
        sourceRecordIDs: {"42": row["_id"] as int},
        cloudMovedSourceUploadedFileIDs: const {},
      );

      expect(await db.get("SELECT title FROM files"), {"title": "image.jpg"});
    },
  );

  test("updates every representation of the selected uploaded file", () async {
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
      ["42", 77, 101, "selected.jpg", "1", "1"],
    );
    await db.execute(
      """
      INSERT INTO files (
        local_id, uploaded_file_id, collection_id, title, modification_time,
        creation_time
      ) VALUES (?, ?, ?, ?, ?, ?)
      """,
      ["42", 77, 202, "same-uploaded-file.jpg", "1", "1"],
    );
    await db.execute(
      """
      INSERT INTO files (
        local_id, uploaded_file_id, collection_id, title, modification_time,
        creation_time
      ) VALUES (?, ?, ?, ?, ?, ?)
      """,
      ["42", 88, 303, "unrelated.jpg", "1", "1"],
    );
    final selected = await db.get(
      "SELECT _id FROM files WHERE collection_id = ?",
      [101],
    );

    await FilesDB.instance.reconcileDeviceFolderMove(
      sourcePathID: "source",
      targetPathID: "destination",
      targetFolderName: "Destination",
      destinations: const {
        "42": (localID: "99", displayName: "selected (1).jpg"),
      },
      sourceRecordIDs: {"42": selected["_id"] as int},
      cloudMovedSourceUploadedFileIDs: const {},
    );

    expect(
      await db.getAll(
        "SELECT local_id, collection_id FROM files ORDER BY collection_id",
      ),
      [
        {"local_id": "99", "collection_id": 101},
        {"local_id": "99", "collection_id": 202},
        {"local_id": "42", "collection_id": 303},
      ],
    );
  });

  test(
    "updates uploaded siblings when the selected local row is pending",
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
        ["42", -1, 101, "pending.jpg", "1", "1"],
      );
      await db.execute(
        """
      INSERT INTO files (
        local_id, uploaded_file_id, collection_id, title, modification_time,
        creation_time
      ) VALUES (?, ?, ?, ?, ?, ?)
      """,
        ["42", 77, 202, "moved.jpg", "1", "1"],
      );
      await db.execute(
        """
      INSERT INTO files (
        local_id, uploaded_file_id, collection_id, title, modification_time,
        creation_time
      ) VALUES (?, ?, ?, ?, ?, ?)
      """,
        ["42", 77, 303, "linked.jpg", "1", "1"],
      );
      final row = await db.get(
        "SELECT _id FROM files WHERE local_id = ? AND uploaded_file_id = ?",
        ["42", -1],
      );

      await FilesDB.instance.reconcileDeviceFolderMove(
        sourcePathID: "source",
        targetPathID: "destination",
        targetFolderName: "Destination",
        destinations: const {
          "42": (localID: "99", displayName: "pending (1).jpg"),
        },
        sourceRecordIDs: {"42": row["_id"] as int},
        cloudMovedSourceUploadedFileIDs: const {},
      );

      expect(
        await db.getAll(
          "SELECT local_id, collection_id FROM files ORDER BY collection_id",
        ),
        [
          {"local_id": "99", "collection_id": null},
          {"local_id": "99", "collection_id": 202},
          {"local_id": "99", "collection_id": 303},
        ],
      );
      expect(await db.getAll("SELECT id, path_id FROM device_files"), [
        {"id": "99", "path_id": "destination"},
      ]);
    },
  );

  test("updates explicit cloud-moved uploaded records", () async {
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
      ["42", -1, 101, "pending.jpg", "1", "1"],
    );
    await db.execute(
      """
      INSERT INTO files (
        local_id, uploaded_file_id, collection_id, title, modification_time,
        creation_time
      ) VALUES (?, ?, ?, ?, ?, ?)
      """,
      ["uploaded-source", 77, 202, "moved.jpg", "1", "1"],
    );
    final row = await db.get(
      "SELECT _id FROM files WHERE local_id = ? AND uploaded_file_id = ?",
      ["42", -1],
    );

    await FilesDB.instance.reconcileDeviceFolderMove(
      sourcePathID: "source",
      targetPathID: "destination",
      targetFolderName: "Destination",
      destinations: const {
        "42": (localID: "99", displayName: "pending (1).jpg"),
      },
      sourceRecordIDs: {"42": row["_id"] as int},
      cloudMovedSourceUploadedFileIDs: const {
        "42": [77],
      },
    );

    expect(
      await db.getAll(
        "SELECT local_id, collection_id FROM files ORDER BY collection_id",
      ),
      [
        {"local_id": "99", "collection_id": null},
        {"local_id": "99", "collection_id": 202},
      ],
    );
  });
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.documentsPath);

  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}
