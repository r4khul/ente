import 'dart:async';

import 'package:email_validator/email_validator.dart';
import "package:ente_components/ente_components.dart";
import "package:ente_strings/ente_strings.dart";
import 'package:flutter/material.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/services/account/user_service.dart';
import "package:photos/ui/account/login_page.dart";
import "package:photos/ui/account/onboarding_page_scaffold.dart";
import 'package:photos/ui/common/web_page.dart';
import "package:styled_text/styled_text.dart";

class EmailEntryPage extends StatefulWidget {
  const EmailEntryPage({super.key, this.referralSource});

  final String? referralSource;

  @override
  State<EmailEntryPage> createState() => _EmailEntryPageState();
}

class _EmailEntryPageState extends State<EmailEntryPage> {
  final _config = Configuration.instance;
  final _emailController = TextEditingController();

  String? _email;
  bool _emailIsValid = false;
  bool _showEmailValidation = false;
  bool _hasAgreedToTOS = false;
  bool _isSubmitting = false;
  Timer? _emailValidationTimer;

  @override
  void initState() {
    super.initState();
    final storedEmail = _config.getEmail();
    if (storedEmail != null && storedEmail.isNotEmpty) {
      _email = storedEmail;
      _emailController.text = storedEmail;
      _emailIsValid = EmailValidator.validate(storedEmail);
    }
  }

  @override
  void dispose() {
    _emailValidationTimer?.cancel();
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isKeyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final terms = TextFieldTapRegion(
      groupId: _emailController,
      child: _getTOSAgreement(),
    );
    return OnboardingPageScaffold(
      title: context.strings.createAccountTitle,
      illustration: OnboardingIllustration.login,
      showDeveloperSettingsTapArea: true,
      body: _getBody(terms: isKeyboardOpen ? terms : null),
      actions: [
        if (!isKeyboardOpen) terms,
        TextFieldTapRegion(
          groupId: _emailController,
          child: ButtonComponent(
            key: const ValueKey("createAccountButton"),
            label: context.strings.createAccountTitle,
            shouldShowSuccessState: false,
            isDisabled: !_isFormValid(),
            onTap: _isFormValid() ? _submitCreateAccount : null,
          ),
        ),
        if (!isKeyboardOpen)
          OnboardingAccountPrompt(
            question: context.strings.alreadyHaveAnAccount,
            actionLabel: context.strings.logInLabel,
            onTap: () async {
              FocusScope.of(context).unfocus();
              await Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const LoginPage()));
            },
          ),
      ],
    );
  }

  Widget _getBody({Widget? terms}) {
    return AutofillGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextInputComponent(
            label: context.strings.email,
            hintText: context.strings.emailHint,
            controller: _emailController,
            groupId: _emailController,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            autocorrect: false,
            isRequired: true,
            shouldUnfocusOnClearOrSubmit: true,
            onSubmit: _isFormValid() ? (_) => _submitCreateAccount() : null,
            onChanged: _onEmailChanged,
            message: _showEmailValidation
                ? _emailIsValid
                      ? context.strings.validEmailAddress
                      : context.strings.invalidEmailAddress
                : null,
            messageType: !_showEmailValidation
                ? TextInputComponentMessageType.helper
                : _emailIsValid
                ? TextInputComponentMessageType.success
                : TextInputComponentMessageType.alert,
          ),
          if (terms != null) ...[const SizedBox(height: Spacing.lg), terms],
        ],
      ),
    );
  }

  Future<void> _submitCreateAccount() async {
    if (!_isFormValid() || _isSubmitting) {
      return;
    }
    final email = _email!;
    _isSubmitting = true;
    try {
      _config.resetVolatilePassword();
      await UserService.instance.setEmail(email);
      await UserService.instance.setRefSource(
        widget.referralSource?.trim() ?? '',
      );
      if (!mounted) return;
      await UserService.instance.sendOtt(
        context,
        email,
        isCreateAccountScreen: true,
        purpose: "signup",
      );
    } finally {
      _isSubmitting = false;
    }
  }

  void _onEmailChanged(String value) {
    final trimmed = value.trim();
    if (trimmed == _email) return;
    _emailValidationTimer?.cancel();

    final isValid = EmailValidator.validate(trimmed);

    setState(() {
      _email = trimmed;
      _emailIsValid = isValid;
      _showEmailValidation = false;
    });

    if (trimmed.isNotEmpty) {
      _emailValidationTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) {
          setState(() {
            _showEmailValidation = true;
          });
        }
      });
    }
  }

  Widget _getTOSAgreement() {
    final colors = context.componentColors;
    return GestureDetector(
      onTap: () {
        setState(() {
          _hasAgreedToTOS = !_hasAgreedToTOS;
        });
      },
      behavior: HitTestBehavior.translucent,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: CheckboxComponent(
              selected: _hasAgreedToTOS,
              onChanged: (value) {
                setState(() {
                  _hasAgreedToTOS = value;
                });
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: StyledText(
              text: context.strings.signUpTerms,
              style: TextStyles.body.copyWith(color: colors.textLighter),
              tags: {
                'u-terms': StyledTextActionTag(
                  (String? text, Map<String?, String?> attrs) =>
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (BuildContext context) {
                            return WebPage(
                              context.strings.termsOfServicesTitle,
                              "https://ente.com/terms",
                            );
                          },
                        ),
                      ),
                  style: TextStyle(
                    decoration: TextDecoration.underline,
                    decorationColor: colors.textLighter,
                    color: colors.textLighter,
                  ),
                ),
                'u-policy': StyledTextActionTag(
                  (String? text, Map<String?, String?> attrs) =>
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (BuildContext context) {
                            return WebPage(
                              context.strings.privacyPolicyTitle,
                              "https://ente.com/privacy",
                            );
                          },
                        ),
                      ),
                  style: TextStyle(
                    decoration: TextDecoration.underline,
                    decorationColor: colors.textLighter,
                    color: colors.textLighter,
                  ),
                ),
              },
            ),
          ),
        ],
      ),
    );
  }

  bool _isFormValid() {
    return _emailIsValid && _hasAgreedToTOS;
  }
}
