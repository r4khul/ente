import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_local_notifications/flutter_local_notifications.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/services/notification_service.dart";
import "package:shared_preferences/shared_preferences.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  const channel = MethodChannel("dexterous.com/flutter/local_notifications");
  const attemptedKey = "has_attempted_notification_permission";
  late SharedPreferences preferences;
  late List<String> calls;
  late Future<bool> Function() checkPermission;
  late Future<bool> Function() requestPermission;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    NotificationService.instance.init(preferences);
    calls = [];
    checkPermission = () async => false;
    requestPermission = () async => false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case "areNotificationsEnabled":
              return checkPermission();
            case "requestNotificationsPermission":
              return requestPermission();
            case "initialize":
              return true;
            default:
              throw StateError("Unexpected notification call: ${call.method}");
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<BuildContext> mountContext(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );
    return context;
  }

  testWidgets("first denial stays in the app and records a completed request", (
    tester,
  ) async {
    final response = Completer<bool>();
    requestPermission = () => response.future;
    final context = await mountContext(tester);
    final result = NotificationService.instance.requestPermissions(context);
    await tester.pump();

    expect(calls, contains("requestNotificationsPermission"));
    expect(preferences.getBool(attemptedKey), isNull);

    response.complete(false);
    await tester.pump();
    expect(await result, isFalse);
    expect(preferences.getBool(attemptedKey), isTrue);
    expect(
      calls.where((call) => call == "requestNotificationsPermission"),
      hasLength(1),
    );
  });

  testWidgets(
    "leaving before the permission check completes keeps first retry",
    (tester) async {
      final response = Completer<bool>();
      checkPermission = () => response.future;
      final context = await mountContext(tester);
      final result = NotificationService.instance.requestPermissions(context);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      response.complete(false);
      await tester.pump();

      expect(await result, isFalse);
      expect(calls, isNot(contains("requestNotificationsPermission")));
      expect(preferences.getBool(attemptedKey), isNull);
    },
  );

  testWidgets("a failed native request does not consume the first retry", (
    tester,
  ) async {
    requestPermission = () async =>
        throw PlatformException(code: "unavailable");
    final context = await mountContext(tester);

    await expectLater(
      NotificationService.instance.requestPermissions(context),
      throwsA(isA<PlatformException>()),
    );
    expect(preferences.getBool(attemptedKey), isNull);
  });

  testWidgets("existing authorization does not request permission again", (
    tester,
  ) async {
    checkPermission = () async => true;
    final context = await mountContext(tester);

    expect(
      await NotificationService.instance.requestPermissions(context),
      isTrue,
    );
    expect(calls, isNot(contains("requestNotificationsPermission")));
    expect(preferences.getBool(attemptedKey), isNull);
  });
}
