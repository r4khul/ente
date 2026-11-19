import "dart:typed_data";

import "package:dio/dio.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/ente_theme_data.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/account/user_service.dart";
import "package:photos/ui/account/referral_source_page.dart";
import "package:photos/ui/payment/subscription.dart";

import "accounts_test_support.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final server = _RecordingAdapter();

  setUpAll(() async {
    await initializeAccountsTest(FakeAccountsClient());
    ServiceLocator.instance.enteDio.httpClientAdapter = server;
  });

  setUp(server.requests.clear);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> openFromOnboarding(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: lightThemeData,
        localizationsDelegates: StringsLocalizations.localizationsDelegates,
        supportedLocales: StringsLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => closeOnboardingSubscription(context),
            child: const Text("Leave plans"),
          ),
        ),
      ),
    );
    await tester.tap(find.text("Leave plans"));
    await settle(tester);
  }

  testWidgets("a new account is asked once and one tap saves the answer", (
    tester,
  ) async {
    await UserService.instance.setShouldAskReferralSource(true);
    await openFromOnboarding(tester);
    final context = tester.element(find.byType(ReferralSourcePage));

    closeOnboardingSubscription(
      tester.element(find.text("Leave plans", skipOffstage: false)),
    );
    await settle(tester);
    await tester.tap(find.text(context.strings.hearUsWhereFriend));
    await settle(tester);

    expect(find.byType(ReferralSourcePage), findsNothing);
    expect(server.requests.single.path, "/users/source");
    expect(server.requests.single.data, {"source": "Friend or family"});

    await tester.tap(find.text("Leave plans"));
    await settle(tester);
    expect(find.byType(ReferralSourcePage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets("a typed answer is saved from the keyboard", (tester) async {
    await UserService.instance.setShouldAskReferralSource(true);
    await openFromOnboarding(tester);

    await tester.enterText(find.byType(TextField), " A podcast ");
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    expect(find.byType(ReferralSourcePage), findsNothing);
    expect(server.requests.single.data, {"source": "A podcast"});
    expect(tester.takeException(), isNull);
  });

  test("an answer that could not be sent is sent later", () async {
    server.isOffline = true;
    await UserService.instance.submitReferralSource("A podcast");
    expect(server.requests, isEmpty);

    server.isOffline = false;
    await UserService.instance.syncPendingReferralSource();
    await UserService.instance.syncPendingReferralSource();
    expect(server.requests.single.data, {"source": "A podcast"});
  });

  testWidgets("skip saves nothing", (tester) async {
    await UserService.instance.setShouldAskReferralSource(true);
    await openFromOnboarding(tester);

    await tester.tap(find.byKey(const ValueKey("referralSourceSkipButton")));
    await settle(tester);

    expect(find.byType(ReferralSourcePage), findsNothing);
    expect(server.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  bool isOffline = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (isOffline) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: "offline",
      );
    }
    requests.add(options);
    return ResponseBody.fromString("", 200);
  }

  @override
  void close({bool force = false}) {}
}
