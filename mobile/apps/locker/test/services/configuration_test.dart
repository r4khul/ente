import 'package:ente_lock_screen/lock_screen_settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locker/services/configuration.dart';

import '../test_utils/configuration_test_util.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('logout clears the secure session and app lock', () async {
    final root = await setupLockerConfigurationForTest('session');
    addTearDown(() async {
      clearLockerConfigurationTestHandlers();
      await root.delete(recursive: true);
    });
    final config = Configuration.instance;
    const storage = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    await config.setKey('account-key');
    await config.setToken('session');
    await storage.invokeMethod<void>('write', {
      'key': LockScreenSettings.pin,
      'value': 'pin-hash',
    });
    expect(config.hasConfiguredAccount(), true);

    await config.logout();

    expect(config.isLoggedIn(), false);
    expect(await storage.invokeMethod<Map>('readAll'), isEmpty);
  });
}
