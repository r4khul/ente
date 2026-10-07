import "package:flutter_test/flutter_test.dart";
import "package:photo_manager/photo_manager.dart";
import "package:photos/services/backup_preference_service.dart";
import "package:photos/services/permission/service.dart";
import "package:shared_preferences/shared_preferences.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("existing users retain their backup choice when upgrading", () async {
    SharedPreferences.setMockInitialValues({
      "has_manual_backup_folder_selection": true,
      "has_selected_any_folder_for_backup": true,
      "backup_only_new_since_epoch": 123,
      "onboarding_permission_skipped": true,
    });
    final preferences = await SharedPreferences.getInstance();
    final backup = BackupPreferenceService(preferences);

    expect(backup.hasPendingOnboardingBackupChoice, isFalse);
    expect(backup.hasManualFolderSelection, isTrue);
    expect(backup.hasSelectedAnyBackupFolder, isTrue);
    expect(backup.onlyNewSinceEpoch, 123);
    expect(backup.hasSkippedOnboardingPermission, isTrue);
  });

  test(
    "photo access and restart do not complete a new account's backup choice",
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await BackupPreferenceService(
        preferences,
      ).setOnboardingBackupChoicePending(true);
      await PermissionService(
        preferences,
      ).onUpdatePermission(PermissionState.authorized);

      final restored = BackupPreferenceService(preferences);
      expect(PermissionService(preferences).hasGrantedPermissions(), isTrue);
      expect(restored.hasPendingOnboardingBackupChoice, isTrue);
      expect(restored.hasSelectedAnyBackupFolder, isFalse);

      await restored.setOnboardingBackupChoicePending(false);
      expect(
        BackupPreferenceService(preferences).hasPendingOnboardingBackupChoice,
        isFalse,
      );
      expect(PermissionService(preferences).hasGrantedPermissions(), isTrue);
    },
  );
}
