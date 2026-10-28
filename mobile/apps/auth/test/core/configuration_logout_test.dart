import 'dart:io';

import 'package:ente_auth/core/configuration.dart';
import 'package:ente_configuration/base_configuration.dart';
import 'package:ente_lock_screen/lock_screen_settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    final root = await Directory.systemTemp.createTemp('auth_offline_lock_');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(paths, null);
      await root.delete(recursive: true);
    });
  });

  test('offline PIN lock survives sign-in and reinitialization', () async {
    SharedPreferences.setMockInitialValues({
      Configuration.hasOptedForOfflineModeKey: true,
      LockScreenSettings.keyAppLockSet: true,
      LockScreenSettings.keyHasMigratedLockScreenChanges: true,
    });
    FlutterSecureStorage.setMockInitialValues({
      Configuration.offlineAuthSecretKey: 'offline-key',
      LockScreenSettings.pin: 'pin-hash',
      LockScreenSettings.saltKey: 'salt',
    });
    final config = Configuration.instance;
    final lock = LockScreenSettings.instance;
    const storage = FlutterSecureStorage();

    Future<void> expectPinLockPreserved() async {
      expect(await storage.read(key: LockScreenSettings.pin), 'pin-hash');
      expect(await storage.read(key: LockScreenSettings.saltKey), 'salt');
      expect(lock.getIsAppLockSet(), true);
      expect(await lock.shouldShowLockScreen(), true);
    }

    await config.init([]);
    await lock.init(config, hasOptedForOfflineMode: true);
    expect(config.isLoggedIn(), false);
    await expectPinLockPreserved();

    await config.setKey('account-key');
    await config.setToken('token');
    expect(config.hasConfiguredAccount(), true);
    await expectPinLockPreserved();

    await config.init([]);
    await lock.init(
      config,
      hasOptedForOfflineMode: config.hasOptedForOfflineMode(),
    );
    expect(config.hasConfiguredAccount(), true);
    await expectPinLockPreserved();
  });

  test(
    'missing account key recovers while retaining the offline key',
    () async {
      SharedPreferences.setMockInitialValues({
        BaseConfiguration.tokenKey: 'legacy',
      });
      FlutterSecureStorage.setMockInitialValues({
        BaseConfiguration.keyKey: 'account-key',
        BaseConfiguration.secretKeyKey: 'secret-key',
        Configuration.authSecretKeyKey: 'auth-key',
        Configuration.offlineAuthSecretKey: 'offline-key',
        LockScreenSettings.pin: 'pin-hash',
      });
      final config = Configuration.instance;
      const storage = FlutterSecureStorage();
      await config.init([]);
      expect(config.hasConfiguredAccount(), true);

      await storage.delete(key: BaseConfiguration.keyKey);
      await config.init([]);
      expect(config.getToken(), isNull);
      expect(config.hasConfiguredAccount(), false);
      expect(await storage.readAll(), {
        Configuration.offlineAuthSecretKey: 'offline-key',
      });

      await config.optForOfflineMode();
      await config.init([]);
      expect(config.hasOptedForOfflineMode(), true);
      expect(
        await storage.read(key: Configuration.offlineAuthSecretKey),
        'offline-key',
      );
    },
  );
}
