import "package:ente_base/models/accounts.dart";
import "package:ente_components/ente_components.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:flutter/rendering.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/ente_theme_data.dart";
import "package:photos/ui/account/email_entry_page.dart";
import "package:photos/ui/account/login_page.dart";
import "package:photos/ui/account/ott_verification_page.dart";
import "package:photos/ui/account/password_entry_page.dart";
import "package:photos/ui/account/recovery_page.dart";
import "package:photos/ui/components/base_bottom_sheet.dart";

import "accounts_test_support.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final client = FakeAccountsClient();

  setUpAll(() => initializeAccountsTest(client));

  setUp(() {
    client.failure = null;
  });

  // The illustrations animate continuously, so pump a bounded stretch.
  Future<void> settle(WidgetTester tester, [int frames = 12]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Widget app(Widget home, {Locale? locale}) {
    return MaterialApp(
      theme: lightThemeData,
      locale: locale,
      localizationsDelegates: StringsLocalizations.localizationsDelegates,
      supportedLocales: StringsLocalizations.supportedLocales,
      home: home,
    );
  }

  testWidgets("login validates the email after typing pauses", (tester) async {
    await tester.pumpWidget(app(const LoginPage()));
    await settle(tester, 20);
    final context = tester.element(find.byType(LoginPage));
    expect(find.text("person@example.com"), findsOneWidget);
    expect(find.text(context.strings.validEmailAddress), findsNothing);
    expect(find.text(context.strings.invalidEmailAddress), findsNothing);

    await tester.enterText(find.byType(TextField), "bad@");
    await settle(tester, 20);
    expect(find.text(context.strings.invalidEmailAddress), findsOneWidget);
    expect(
      tester
          .widget<ButtonComponent>(find.byKey(const ValueKey("logInButton")))
          .isDisabled,
      isTrue,
    );

    await tester.enterText(find.byType(TextField), "new@example.com");
    await settle(tester, 20);
    expect(find.text(context.strings.validEmailAddress), findsOneWidget);
    expect(
      tester
          .widget<ButtonComponent>(find.byKey(const ValueKey("logInButton")))
          .isDisabled,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets("header collapses while the keyboard is open", (tester) async {
    tester.view.physicalSize = const Size(375, 831);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 44);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(const LoginPage()));
    await settle(tester);
    final context = tester.element(find.byType(LoginPage));
    final title = find.text(context.strings.loginToEnte);
    expect(tester.getTopLeft(title).dy, greaterThan(200));

    tester.view.viewInsets = const FakeViewPadding(bottom: 291);
    await settle(tester);
    expect(tester.getTopLeft(title).dy, greaterThan(200));

    tester.view.viewInsets = FakeViewPadding.zero;
    await settle(tester);
    expect(tester.getTopLeft(title).dy, greaterThan(200));
    expect(tester.takeException(), isNull);
  });

  testWidgets("incorrect code clears the field and refocuses it", (
    tester,
  ) async {
    await tester.pumpWidget(
      app(const OTTVerificationPage("person@example.com")),
    );
    await settle(tester);
    client.failure = const AccountsError.incorrectEmailCode();
    final pin = tester.widget<PinInputComponent>(
      find.byType(PinInputComponent),
    );
    pin.controller.text = "123456";
    await settle(tester, 20);
    final context = tester.element(find.byType(OTTVerificationPage));
    expect(find.text(context.strings.incorrectCode), findsOneWidget);

    await tester.tap(find.byType(BottomSheetCloseButton));
    await settle(tester, 20);
    expect(find.text(context.strings.incorrectCode), findsNothing);
    expect(find.byType(OTTVerificationPage), findsOneWidget);
    expect(pin.controller.text, isEmpty);
    expect(pin.focusNode!.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets("forgot recovery key sheet closes from its button", (
    tester,
  ) async {
    await tester.pumpWidget(app(const RecoveryPage(isForgotPassword: true)));
    await settle(tester);
    final context = tester.element(find.byType(RecoveryPage));
    await tester.tap(find.text(context.strings.forgotRecoveryKey));
    await settle(tester);
    expect(
      find.text(context.strings.noRecoveryKeyNoDecryption),
      findsOneWidget,
    );

    await tester.tap(find.text(context.strings.ok));
    await settle(tester);
    expect(find.text(context.strings.noRecoveryKeyNoDecryption), findsNothing);
    expect(find.byType(RecoveryPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets("sign-up enables once the email and terms are set", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 831);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(const EmailEntryPage()));
    await settle(tester);
    await tester.enterText(find.byType(TextField), "new@example.com");
    await settle(tester, 15);
    final button = find.byKey(const ValueKey("createAccountButton"));
    expect(tester.widget<ButtonComponent>(button).isDisabled, isTrue);

    await tester.tap(find.byType(CheckboxComponent));
    await settle(tester);
    expect(tester.widget<ButtonComponent>(button).isDisabled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets("set password confirms the password and continues", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 20);
    addTearDown(tester.view.reset);
    client.requests.clear();
    await tester.pumpWidget(
      app(const PasswordEntryPage(mode: PasswordEntryMode.set)),
    );
    await settle(tester);
    final context = tester.element(find.byType(PasswordEntryPage));
    final fields = find.byType(TextField);
    final button = find.byKey(const ValueKey("setPasswordButton"));
    expect(tester.widget<ButtonComponent>(button).isDisabled, isTrue);

    tester.view.viewInsets = const FakeViewPadding(bottom: 291);
    await tester.showKeyboard(fields.at(0));
    await tester.enterText(fields.at(0), "correct horse battery staple");
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await settle(tester);
    expect(tester.widget<TextField>(fields.at(1)).focusNode!.hasFocus, isTrue);

    await tester.enterText(fields.at(1), "correct horse battery stapl");
    await settle(tester, 15);
    expect(
      find.text(context.strings.passwordsDontMatch).hitTestable(),
      findsOneWidget,
    );
    final confirmTop = tester.getTopLeft(fields.at(1)).dy;
    await tester.enterText(fields.at(1), "correct horse battery stap");
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getTopLeft(fields.at(1)).dy, confirmTop);

    await tester.enterText(fields.at(1), "correct horse battery staple");
    await tester.pump();
    expect(
      find.text(context.strings.passwordsMatch).hitTestable(),
      findsOneWidget,
    );
    expect(tester.widget<ButtonComponent>(button).isDisabled, isFalse);

    await tester.enterText(fields.at(1), "correct horse battery stapl");
    await tester.pump();
    expect(find.text(context.strings.passwordsMatch), findsNothing);
    expect(find.text(context.strings.passwordsDontMatch), findsOneWidget);
    expect(tester.widget<ButtonComponent>(button).isDisabled, isTrue);

    await tester.enterText(fields.at(0), "a");
    await tester.pump();
    expect(find.text(context.strings.strongPassword), findsNothing);
    expect(find.text(context.strings.weakStrength), findsOneWidget);
    await tester.enterText(fields.at(0), "correct horse battery staple");
    await tester.enterText(fields.at(1), "correct horse battery staple");
    await settle(tester, 15);

    client.failure = const AccountsError.keyDerivation();
    await tester.tap(button);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(client.requests, [
      {"password": "correct horse battery staple"},
    ]);
    expect(find.text(context.strings.insecureDevice), findsOneWidget);

    await tester.tap(find.byType(BottomSheetCloseButton));
    await settle(tester);
    await tester.tap(button);
    await settle(tester);
    expect(client.requests, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets("set password pairs the new password with the account email", (
    tester,
  ) async {
    await tester.pumpWidget(
      app(const PasswordEntryPage(mode: PasswordEntryMode.set)),
    );
    await settle(tester);
    final group = tester.state<AutofillGroupState>(find.byType(AutofillGroup));
    final hints = group.autofillClients.expand(
      (client) =>
          client.textInputConfiguration.autofillConfiguration.autofillHints,
    );
    expect(
      hints,
      containsAll([AutofillHints.email, AutofillHints.newPassword]),
    );
  });

  testWidgets("set password title fits with large French text", (tester) async {
    final font = FontLoader("packages/ente_components/Outfit")
      ..addFont(
        rootBundle.load("packages/ente_components/fonts/Outfit-SemiBold.ttf"),
      );
    await font.load();
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 20);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      app(
        const PasswordEntryPage(mode: PasswordEntryMode.set),
        locale: const Locale("fr"),
      ),
    );
    await settle(tester);

    final context = tester.element(find.byType(PasswordEntryPage));
    final title = find.text(context.strings.setPasswordTitle);
    expect(
      tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
      false,
    );
    expect(tester.takeException(), isNull);
  });
}
