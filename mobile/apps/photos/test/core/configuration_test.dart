import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/events/signed_in_event.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/settings/local_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const storage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final config = Configuration.instance;
  final values = <String, String>{};
  late SharedPreferences preferences;
  late Directory root;
  Completer<void>? writeGate;
  bool unavailableKey = false;
  bool ignoreWrites = false;
  var signedInEvents = 0;
  late StreamSubscription<SignedInEvent> subscription;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('photos_session_');
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    ServiceLocator.instance.localSettings = LocalSettings(preferences);
    messenger.setMockMethodCallHandler(storage, (call) async {
      final arguments = (call.arguments as Map?) ?? {};
      final key = arguments['key'] as String?;
      switch (call.method) {
        case 'read':
          if (unavailableKey && key == Configuration.keyKey) {
            throw PlatformException(code: 'unavailable');
          }
          return values[key];
        case 'write':
          await writeGate?.future;
          if (!ignoreWrites) values[key!] = arguments['value'] as String;
          return null;
        case 'delete':
          values.remove(key);
          return null;
        case 'deleteAll':
          values.clear();
          return null;
        default:
          throw StateError('Unexpected storage call: ${call.method}');
      }
    });
  });

  tearDownAll(() async {
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(storage, null);
    await root.delete(recursive: true);
  });

  setUp(() async {
    writeGate = null;
    unavailableKey = false;
    ignoreWrites = false;
    values.clear();
    await preferences.clear();
    await preferences.setString(Configuration.tokenKey, 'legacy-session');
    values.addAll({
      Configuration.keyKey: 'bWFzdGVy',
      Configuration.secretKeyKey: 'c2VjcmV0',
    });
    signedInEvents = 0;
    subscription = Bus.instance.on<SignedInEvent>().listen((_) {
      signedInEvents++;
    });
  });

  tearDown(() => subscription.cancel());

  test(
    'migration preserves the account and sign-in waits for persistence',
    () async {
      unavailableKey = true;
      await expectLater(
        config.init(preferences),
        throwsA(isA<PlatformException>()),
      );
      expect(values[Configuration.keyKey], 'bWFzdGVy');
      expect(values[Configuration.secretKeyKey], 'c2VjcmV0');
      unavailableKey = false;
      await config.init(preferences);
      await config.init(preferences);
      expect(config.getToken(), 'legacy-session');
      expect(config.hasConfiguredAccount(), true);
      expect(values[Configuration.keyKey], 'bWFzdGVy');
      expect(values[Configuration.secretKeyKey], 'c2VjcmV0');
      expect(preferences.containsKey(Configuration.tokenKey), false);
      expect(signedInEvents, 0);

      ignoreWrites = true;
      await expectLater(config.setToken('new-session'), throwsStateError);
      expect(config.getToken(), 'legacy-session');
      expect(signedInEvents, 0);
      ignoreWrites = false;
      writeGate = Completer<void>();
      final signIn = config.setToken('new-session');
      await Future<void>.delayed(Duration.zero);
      expect(config.getToken(), 'legacy-session');
      expect(signedInEvents, 0);
      writeGate!.complete();
      await signIn;
      await Future<void>.delayed(Duration.zero);
      expect(config.getToken(), 'new-session');
      expect(values[Configuration.tokenKey], 'new-session');
      expect(signedInEvents, 1);
    },
  );
}
