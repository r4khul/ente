import 'dart:async';

import 'package:ente_configuration/secure_session_token.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const secureStorage = FlutterSecureStorage();
  late SharedPreferences preferences;
  late SecureSessionToken session;
  late Map<String, String> values;
  bool ignoreWrites = false;
  Completer<void>? writeStarted;
  Completer<void>? finishWrite;
  int resets = 0;

  Future<void> initialize() => session.initialize(
    resetSecureStorage: () async {
      resets++;
      values.clear();
    },
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({'token': 'legacy'});
    preferences = await SharedPreferences.getInstance();
    values = {'key': 'master-key', 'secret_key': 'secret-key'};
    ignoreWrites = false;
    writeStarted = null;
    finishWrite = null;
    resets = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final key = call.arguments['key'] as String?;
      switch (call.method) {
        case 'read':
          return values[key];
        case 'write':
          writeStarted?.complete();
          await finishWrite?.future;
          if (!ignoreWrites) values[key!] = call.arguments['value'] as String;
          return null;
        case 'delete':
          values.remove(key);
          return null;
        default:
          throw UnimplementedError(call.method);
      }
    });
    session = SecureSessionToken(preferences, secureStorage);
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'upgrade preserves keys and the secure session wins on relaunch',
    () async {
      expect(
        await SecureSessionToken.read(preferences, secureStorage),
        'legacy',
      );
      await initialize();
      expect(session.token, 'legacy');
      expect(values, {
        'key': 'master-key',
        'secret_key': 'secret-key',
        'token': 'legacy',
      });
      expect(preferences.containsKey('token'), false);

      await preferences.setString('token', 'stale');
      values['token'] = 'current';
      await initialize();
      expect(session.token, 'current');
      expect(preferences.containsKey('token'), false);
      expect(values['key'], 'master-key');
      expect(resets, 0);
    },
  );

  test(
    'failed migration readback retains the input and can be retried',
    () async {
      ignoreWrites = true;
      await expectLater(initialize(), throwsStateError);
      expect(session.token, null);
      expect(preferences.getString('token'), 'legacy');
      expect(values, {'key': 'master-key', 'secret_key': 'secret-key'});

      ignoreWrites = false;
      await initialize();
      expect(session.token, 'legacy');
      expect(values['token'], 'legacy');
      expect(preferences.containsKey('token'), false);
    },
  );

  test('logout cancels the first and subsequent in-flight sign-ins', () async {
    await initialize();
    Future<void> cancelSignIn() async {
      writeStarted = Completer<void>();
      finishWrite = Completer<void>();
      final write = session.setToken('late-token');
      await writeStarted!.future;
      bool clearedAccount = false;
      final clear = session.logout(() async {
        clearedAccount = true;
      });
      expect(session.token, null);
      finishWrite!.complete();
      expect(await write, false);
      expect(await clear, true);
      expect(clearedAccount, true);
      expect(values.containsKey('token'), false);
      await initialize();
      expect(session.token, null);
    }

    await cancelSignIn();
    await cancelSignIn();

    writeStarted = null;
    finishWrite = null;
    expect(await session.setToken('new-session'), true);
    await initialize();
    expect(session.token, 'new-session');
    expect(values['token'], 'new-session');
  });

  test(
    'shared lock keeps old cleanup from crossing into the next session',
    () async {
      var pending = Future<void>.value();
      Future<T> runExclusive<T>(Future<T> Function() action) {
        final result = pending.then((_) => action());
        pending = result.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        );
        return result;
      }

      session = SecureSessionToken(
        preferences,
        secureStorage,
        runExclusive: runExclusive,
      );
      final foreground = SecureSessionToken(
        preferences,
        secureStorage,
        runExclusive: runExclusive,
      );
      writeStarted = Completer<void>();
      finishWrite = Completer<void>();
      final migration = initialize();
      await writeStarted!.future;
      final foregroundInit = foreground.initialize(
        resetSecureStorage: () async =>
            fail('Existing session must be retained'),
      );
      finishWrite!.complete();
      await migration;
      await foregroundInit;
      final cleanupStarted = Completer<void>();
      final finishCleanup = Completer<void>();
      final logout = foreground.logout(() async {
        cleanupStarted.complete();
        await finishCleanup.future;
        await foreground.clearPreferences();
      });
      await cleanupStarted.future;

      var staleCleanupRan = false;
      Future<void> staleCleanup() async => staleCleanupRan = true;
      final overlappingLogout = session.logout(staleCleanup, autoLogout: true);
      writeStarted = null;
      finishWrite = null;
      final nextSignIn = foreground.setToken('new-session');
      await Future<void>.delayed(Duration.zero);
      expect(staleCleanupRan, false);
      finishCleanup.complete();
      expect(await logout, true);
      expect(await overlappingLogout, false);
      expect(await nextSignIn, true);

      expect(await session.logout(staleCleanup, autoLogout: true), false);
      await initialize();
      expect(staleCleanupRan, false);
      expect(session.token, 'new-session');
      expect(values['token'], 'new-session');
    },
  );

  test(
    'reinstall clears stale credentials instead of restoring a session',
    () async {
      await preferences.clear();
      values['token'] = 'old-installation';
      expect(await SecureSessionToken.read(preferences, secureStorage), null);
      await initialize();
      expect(resets, 1);
      expect(session.token, null);
      expect(values, isEmpty);
      expect(
        preferences.getString(SecureSessionToken.stateKey),
        SecureSessionToken.loggedOutState,
      );
    },
  );
}
