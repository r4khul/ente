import "dart:io";

import "package:dio/dio.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:package_info_plus/package_info_plus.dart";
import "package:path_provider_platform_interface/path_provider_platform_interface.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/device_files_db.dart";
import "package:photos/db/files_db.dart";
import "package:photos/ente_theme_data.dart";
import "package:photos/events/sync_status_update_event.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/app_lifecycle_service.dart";
import "package:photos/services/sync/local_sync_service.dart";
import "package:photos/ui/home/loading_photos_widget.dart";
import "package:photos/ui/settings/backup/backup_folder_selection_page.dart";
import "package:shared_preferences/shared_preferences.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  late PathProviderPlatform previousPathProvider;
  late SharedPreferences preferences;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp("onboarding_backup_test_");
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPathProvider(tempDir.path);
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    ServiceLocator.instance.init(
      preferences,
      Dio(),
      Dio(),
      Dio(),
      PackageInfo(
        appName: "Photos",
        packageName: "photos",
        version: "1.0.0",
        buildNumber: "1",
      ),
    );
    AppLifecycleService.instance.onAppInForeground("test");
    await LocalSyncService.instance.init(preferences);
    await FilesDB.instance.getDeviceCollections();
  });

  tearDownAll(() async {
    await (await FilesDB.instance.sqliteAsyncDB).close();
    PathProviderPlatform.instance = previousPathProvider;
    await tempDir.delete(recursive: true);
  });

  for (final importAlreadyCompleted in [true, false]) {
    testWidgets(
      importAlreadyCompleted
          ? "completed import opens onboarding selection without waiting for an event"
          : "repeated import completion opens only one onboarding selection",
      (tester) async {
        await preferences.setBool(
          LocalSyncService.kHasCompletedFirstImportKey,
          importAlreadyCompleted,
        );
        await backupPreferenceService.setOnboardingBackupChoicePending(true);
        bool? selection;
        var returned = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: lightThemeData,
            localizationsDelegates: StringsLocalizations.localizationsDelegates,
            supportedLocales: StringsLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  selection = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => const LoadingPhotosWidget(
                        isOnboardingFlow: false,
                        isBackupOnboarding: true,
                      ),
                    ),
                  );
                  returned = true;
                },
                child: const Text("Select folders"),
              ),
            ),
          ),
        );
        await tester.tap(find.text("Select folders"));
        await tester.pump();
        if (!importAlreadyCompleted) {
          Bus.instance.fire(
            SyncStatusUpdate(SyncStatus.completedFirstGalleryImport),
          );
          Bus.instance.fire(
            SyncStatusUpdate(SyncStatus.completedFirstGalleryImport),
          );
        }
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(() async {
          await FilesDB.instance.getDeviceCollections();
          await FilesDB.instance.getDevicePathIDToImportedFileCount();
        });
        await tester.pump();

        expect(find.byType(BackupFolderSelectionPage), findsOneWidget);
        final picker = tester.widget<BackupFolderSelectionPage>(
          find.byType(BackupFolderSelectionPage),
        );
        expect(picker.isOnboarding, isTrue);
        expect(picker.isFirstBackup, isTrue);

        Navigator.of(
          tester.element(find.byType(BackupFolderSelectionPage)),
        ).pop();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(returned, isTrue);
        expect(selection, isNull);
        expect(
          backupPreferenceService.hasPendingOnboardingBackupChoice,
          isTrue,
        );
        expect(find.byType(BackupFolderSelectionPage), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 60));
      },
    );
  }
}

class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}
