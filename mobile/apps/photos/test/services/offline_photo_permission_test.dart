import "dart:async";

import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photo_manager/photo_manager.dart";
import "package:photos/services/permission/service.dart";
import "package:shared_preferences/shared_preferences.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel("com.fluttercandies/photo_manager");
  late SharedPreferences preferences;
  late PermissionState state;
  late List<String> calls;
  PlatformException? error;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    state = PermissionState.denied;
    calls = [];
    error = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (error != null) throw error!;
          return state.index;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test("first denial becomes a Settings retry after restart", () async {
    final permission = PermissionService(preferences);
    expect(permission.hasRequestedOfflinePhotoPermission, isFalse);
    expect(await permission.requestOfflinePhotoPermissions(), state);
    expect(
      PermissionService(preferences).hasRequestedOfflinePhotoPermission,
      isTrue,
    );
    expect(permission.hasGrantedPermissions(), isFalse);
    expect(calls, ["requestPermissionExtend"]);
  });

  test("failed native request does not consume the first prompt", () async {
    final permission = PermissionService(preferences);
    error = PlatformException(code: "unavailable");
    await expectLater(
      permission.requestOfflinePhotoPermissions(),
      throwsA(isA<PlatformException>()),
    );
    expect(permission.hasRequestedOfflinePhotoPermission, isFalse);
    expect(permission.isPhotoPermissionFlowPending, isFalse);
  });

  test(
    "permission flow stays pending until all native requests finish",
    () async {
      final permission = PermissionService(preferences);
      final results = [Completer<int>(), Completer<int>()];
      var requestIndex = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) => results[requestIndex++].future,
          );
      final first = permission.requestPhotoMangerPermissions();
      final second = permission.requestPhotoMangerPermissions();
      expect(permission.isPhotoPermissionFlowPending, isTrue);
      results.first.complete(PermissionState.limited.index);
      expect(await first, PermissionState.limited);
      expect(permission.isPhotoPermissionFlowPending, isTrue);
      final failure = expectLater(second, throwsA(isA<PlatformException>()));
      results.last.completeError(PlatformException(code: "unavailable"));
      await failure;
      expect(permission.isPhotoPermissionFlowPending, isFalse);
    },
  );

  test(
    "returning denied from Settings does not resume offline entry",
    () async {
      await PermissionService(preferences).setOfflineSettingsGrantPending(true);
      final restored = PermissionService(preferences);
      expect(restored.isPhotoPermissionFlowPending, isTrue);
      expect(await restored.getPendingOfflineSettingsGrant(), isNull);
      expect(restored.isPhotoPermissionFlowPending, isFalse);
      calls.clear();
      expect(await restored.getPendingOfflineSettingsGrant(), isNull);
      expect(calls, isEmpty);
      expect(restored.hasGrantedPermissions(), isFalse);
      expect(preferences.containsKey("ls.app_mode"), isFalse);
    },
  );

  for (final grantedState in [
    PermissionState.authorized,
    PermissionState.limited,
  ]) {
    test("Settings $grantedState survives restart until activation", () async {
      await PermissionService(preferences).setOfflineSettingsGrantPending(true);
      state = grantedState;
      final restored = PermissionService(preferences);
      expect(await restored.getPendingOfflineSettingsGrant(), grantedState);
      expect(restored.hasGrantedPermissions(), isFalse);
      await restored.onUpdatePermission(grantedState);
      await restored.setOfflineSettingsGrantPending(false);
      calls.clear();
      expect(await restored.getPendingOfflineSettingsGrant(), isNull);
      expect(calls, isEmpty);
      expect(restored.hasGrantedPermissions(), isTrue);
    });
  }

  test("a failed Settings check retains the restart recovery intent", () async {
    final permission = PermissionService(preferences);
    await permission.setOfflineSettingsGrantPending(true);
    error = PlatformException(code: "unavailable");
    await expectLater(
      permission.getPendingOfflineSettingsGrant(),
      throwsA(isA<PlatformException>()),
    );
    error = null;
    state = PermissionState.authorized;
    expect(
      await PermissionService(preferences).getPendingOfflineSettingsGrant(),
      PermissionState.authorized,
    );
  });
}
