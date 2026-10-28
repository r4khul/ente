import 'dart:io';

import 'package:ente_base/models/database.dart';
import 'package:ente_configuration/base_configuration.dart';
import 'package:ente_configuration/secure_session_token.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const storage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Map<String, String> values;
  late _Database db;
  bool ignoreDeletes = false;
  bool unavailable = false;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('configuration_logout_');
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    SharedPreferences.setMockInitialValues({
      SecureSessionToken.stateKey: SecureSessionToken.secureState,
      BaseConfiguration.userIDKey: 42,
    });
    values = {
      'token': 'old-session',
      'key': 'old-master-key',
      'secret_key': 'old-secret-key',
      'offline_auth_secret_key': 'retained-key',
    };
    db = _Database();
    ignoreDeletes = false;
    unavailable = false;
    messenger.setMockMethodCallHandler(storage, (call) async {
      final arguments = call.arguments as Map;
      final key = arguments['key'] as String;
      switch (call.method) {
        case 'read':
          if (unavailable) throw PlatformException(code: 'unavailable');
          return values[key];
        case 'write':
          values[key] = arguments['value'] as String;
          return null;
        case 'delete':
          if (!ignoreDeletes) values.remove(key);
          return null;
        default:
          throw StateError(call.method);
      }
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(storage, null);
    await root.delete(recursive: true);
  });

  test(
    'startup finishes interrupted logout before accepting a new account',
    () async {
      final config = _Configuration();
      await config.init([db]);
      unavailable = true;
      await expectLater(config.logout(), throwsA(isA<PlatformException>()));
      unavailable = false;
      ignoreDeletes = true;
      await expectLater(config.logout(), throwsStateError);
      expect(config.isLoggedIn(), false);
      expect(db.hasData, true);

      ignoreDeletes = false;
      db.failClear = true;
      await expectLater(_Configuration().init([db]), throwsStateError);
      db.failClear = false;
      final restarted = _Configuration();
      await restarted.init([db]);
      expect(db.hasData, false);
      expect(restarted.getUserID(), null);
      expect(values, {'offline_auth_secret_key': 'retained-key'});

      await restarted.setKey('new-key');
      await restarted.setToken('new-session');
      expect(restarted.hasConfiguredAccount(), true);
      expect(values['token'], 'new-session');
    },
  );

  test(
    'startup preserves unavailable credentials and recovers missing credentials',
    () async {
      final config = _Configuration();
      unavailable = true;
      await expectLater(config.init([db]), throwsA(isA<PlatformException>()));
      expect(values['token'], 'old-session');
      expect(values['key'], 'old-master-key');
      expect(db.hasData, true);

      unavailable = false;
      values.remove('token');
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('token', 'stale-plaintext');
      await config.init([db]);

      expect(config.isLoggedIn(), false);
      expect(config.getUserID(), null);
      expect(db.hasData, false);
      expect(values, {'offline_auth_secret_key': 'retained-key'});
    },
  );
}

class _Database extends EnteBaseDatabase {
  bool hasData = true;
  bool failClear = false;

  @override
  Future<void> clearTable() async {
    if (failClear) throw StateError('database unavailable');
    hasData = false;
  }
}

class _Configuration extends BaseConfiguration {
  @override
  EnteAppIdentity get appIdentity => const EnteAppIdentity(
    app: 'test',
    clientPackageName: 'test',
    passkeyRedirectUrl: 'test://',
    referralSourcePrefix: 'test',
  );

  @override
  List<String> get secureStorageKeys =>
      BaseConfiguration.accountSecureStorageKeys;
}
