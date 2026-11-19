import "package:ente_components/ente_components.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/ente_theme_data.dart";
import "package:photos/ui/account/email_entry_page.dart";
import "package:photos/ui/account/ott_verification_page.dart";

import "accounts_test_support.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final client = FakeAccountsClient();

  setUpAll(() => initializeAccountsTest(client));

  Widget app(Widget home, {Locale? locale}) {
    return MaterialApp(
      theme: lightThemeData,
      locale: locale,
      localizationsDelegates: StringsLocalizations.localizationsDelegates,
      supportedLocales: StringsLocalizations.supportedLocales,
      home: home,
    );
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 18; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  final createAccount = find.byKey(const ValueKey("createAccountButton"));
  final terms = find.byType(CheckboxComponent);

  testWidgets("sign-up sends the code to the email it submitted", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      app(const EmailEntryPage(showReferralSourceField: false)),
    );
    await settle(tester);
    final email = find.byType(TextField);
    await tester.enterText(email, "first@example.com");
    await settle(tester);
    await tester.tap(terms);
    await settle(tester);

    final field = tester.widget<TextField>(email);
    final gesture = await tester.startGesture(tester.getCenter(createAccount));
    await tester.pump();
    expect(field.focusNode!.hasFocus, isTrue);
    final tap = gesture.up();
    tester.testTextInput.enterText("second@example.com");
    await tap;
    await settle(tester);

    expect(field.controller!.text, "second@example.com");
    expect(client.requests.single["email"], "first@example.com");
    expect(
      tester
          .widget<OTTVerificationPage>(find.byType(OTTVerificationPage))
          .email,
      "first@example.com",
    );
    expect(tester.takeException(), isNull);
  });

  for (final (locale, scale) in [
    (const Locale("en"), 1.0),
    (const Locale("fr"), 2.0),
  ]) {
    testWidgets(
      "sign-up actions stay reachable with the keyboard open in $locale at ${scale}x",
      (tester) async {
        final inter = FontLoader("packages/ente_components/Inter")
          ..addFont(
            rootBundle.load("packages/ente_components/fonts/Inter-Medium.ttf"),
          )
          ..addFont(
            rootBundle.load(
              "packages/ente_components/fonts/Inter-SemiBold.ttf",
            ),
          );
        final outfit = FontLoader("packages/ente_components/Outfit")
          ..addFont(
            rootBundle.load(
              "packages/ente_components/fonts/Outfit-SemiBold.ttf",
            ),
          );
        await Future.wait([inter.load(), outfit.load()]);

        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 20);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(app(const EmailEntryPage(), locale: locale));
        await settle(tester);

        final email = find.byType(TextField);
        await tester.showKeyboard(email);
        tester.view.viewInsets = const FakeViewPadding(bottom: 291);
        await tester.enterText(email, "new@example.com");
        await settle(tester);

        expect(email.hitTestable(), findsOneWidget);
        expect(createAccount.hitTestable(), findsOneWidget);
        if (scale == 1) {
          expect(terms.hitTestable(), findsOneWidget);
        }
        await tester.ensureVisible(terms);
        await tester.pump();
        await tester.tap(terms);
        await tester.pump();

        expect(tester.widget<TextField>(email).focusNode!.hasFocus, isTrue);
        expect(
          tester.widget<ButtonComponent>(createAccount).isDisabled,
          isFalse,
        );
        expect(createAccount.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
