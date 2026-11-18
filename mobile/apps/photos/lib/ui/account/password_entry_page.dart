import "dart:async";

import "package:ente_base/models/accounts.dart";
import "package:ente_components/ente_components.dart";
import 'package:ente_pure_utils/ente_pure_utils.dart';
import "package:ente_strings/ente_strings.dart";
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:password_strength/password_strength.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/events/account_configured_event.dart';
import 'package:photos/events/subscription_purchased_event.dart';
import 'package:photos/services/account/user_service.dart';
import "package:photos/ui/account/onboarding_page_scaffold.dart";
import 'package:photos/ui/account/recovery_key_page.dart';
import 'package:photos/ui/common/web_page.dart';
import "package:photos/ui/components/alert_bottom_sheet.dart";
import "package:photos/ui/components/models/button_type.dart";
import 'package:photos/ui/notification/toast.dart';
import 'package:photos/ui/payment/subscription.dart';
import 'package:photos/utils/dialog_util.dart';
import "package:styled_text/styled_text.dart";

enum PasswordEntryMode { set, update, reset }

class PasswordEntryPage extends StatefulWidget {
  final PasswordEntryMode mode;

  const PasswordEntryPage({required this.mode, super.key});

  @override
  State<PasswordEntryPage> createState() => _PasswordEntryPageState();
}

class _PasswordEntryPageState extends State<PasswordEntryPage> {
  static const kMildPasswordStrengthThreshold = 0.4;
  static const kStrongPasswordStrengthThreshold = 0.7;

  final _logger = Logger((_PasswordEntryPageState).toString());
  final _passwordController1 = TextEditingController();
  final _passwordController2 = TextEditingController();
  final _passwordFieldKey = GlobalKey();
  final _confirmPasswordFieldKey = GlobalKey();
  final _passwordFocusNode = FocusNode();
  final _confirmPasswordFocusNode = FocusNode();
  String? _volatilePassword;
  String _passwordInInputBox = '';
  String _passwordInInputConfirmationBox = '';
  double _passwordStrength = 0.0;

  bool _passwordsMatch = false;
  bool _isPasswordValid = false;
  double? _shownPasswordStrength;
  bool? _shownPasswordsMatch;
  Timer? _passwordStrengthTimer;
  Timer? _confirmPasswordTimer;

  @override
  void initState() {
    super.initState();
    _volatilePassword = Configuration.instance.getVolatilePassword();
    if (_volatilePassword != null) {
      Future.delayed(
        Duration.zero,
        () => _showRecoveryCodeDialog(_volatilePassword!),
      );
    }
  }

  @override
  void dispose() {
    _passwordStrengthTimer?.cancel();
    _confirmPasswordTimer?.cancel();
    _passwordController1.dispose();
    _passwordController2.dispose();
    _passwordFocusNode.dispose();
    _confirmPasswordFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;

    String title = context.strings.setPasswordTitle;
    if (widget.mode == PasswordEntryMode.update) {
      title = context.strings.changePasswordTitle;
    } else if (widget.mode == PasswordEntryMode.reset) {
      title = context.strings.resetPasswordTitle;
    } else if (_volatilePassword != null) {
      title = context.strings.recoveryKey;
    }

    final isFormValid = _passwordsMatch && _isPasswordValid;

    if (_volatilePassword != null) {
      return OnboardingPageScaffold(
        title: title,
        illustration: OnboardingIllustration.recoveryKey,
        body: const SizedBox.shrink(),
      );
    }

    if (widget.mode == PasswordEntryMode.set) {
      return OnboardingPageScaffold(
        title: title,
        illustration: OnboardingIllustration.password,
        body: _getPasswordFields(),
        actions: [
          TextFieldTapRegion(
            groupId: _passwordController1,
            child: ButtonComponent(
              key: const ValueKey("setPasswordButton"),
              label: context.strings.continueLabel,
              shouldShowSuccessState: false,
              isDisabled: !isFormValid,
              onTap: isFormValid ? _submitPassword : null,
            ),
          ),
        ],
      );
    }

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: colors.backgroundBase,
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: colors.backgroundBase,
        leading: widget.mode == PasswordEntryMode.reset
            ? const SizedBox.shrink()
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                color: colors.iconColor,
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
        title: Text(
          title,
          style: TextStyles.large.copyWith(color: colors.textBase),
        ),
        centerTitle: true,
      ),
      body: _getBody(title: title, isFormValid: isFormValid),
    );
  }

  Future<void> _submitPassword() async {
    if (!_passwordsMatch || !_isPasswordValid) {
      return;
    }
    if (widget.mode == PasswordEntryMode.set) {
      await _showRecoveryCodeDialog(_passwordController1.text);
    } else {
      _updatePassword();
    }
    if (!mounted) return;
    FocusScope.of(context).unfocus();
  }

  Widget _getBody({required String title, required bool isFormValid}) {
    final colors = context.componentColors;

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),
              Text(
                context.strings.enterNewPasswordToEncrypt,
                style: TextStyles.body.copyWith(color: colors.textLight),
              ),
              const SizedBox(height: 8),
              StyledText(
                text: context.strings.passwordWarning,
                style: TextStyles.body.copyWith(color: colors.textLight),
                tags: {
                  'underline': StyledTextTag(
                    style: TextStyles.body.copyWith(
                      color: colors.textLight,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                },
              ),
              const SizedBox(height: 24),
              _getPasswordFields(),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: ButtonComponent(
                  variant: ButtonComponentVariant.link,
                  label: context.strings.howItWorks,
                  size: ButtonComponentSize.small,
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (BuildContext context) {
                          return WebPage(
                            context.strings.howItWorks,
                            "https://ente.com/architecture",
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 24),
              ButtonComponent(
                label: title,
                isDisabled: !isFormValid,
                onTap: isFormValid ? _submitPassword : null,
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _getPasswordFields() {
    final email = Configuration.instance.getEmail();

    String? passwordMessage;
    TextInputComponentMessageType passwordMessageType =
        TextInputComponentMessageType.helper;

    final shownPasswordStrength = _shownPasswordStrength;
    if (_passwordInInputBox.isNotEmpty && shownPasswordStrength != null) {
      if (shownPasswordStrength > kStrongPasswordStrengthThreshold) {
        passwordMessage = context.strings.strongPassword;
        passwordMessageType = TextInputComponentMessageType.success;
      } else if (shownPasswordStrength > kMildPasswordStrengthThreshold) {
        passwordMessage = context.strings.moderateStrength;
        passwordMessageType = TextInputComponentMessageType.alert;
      } else {
        passwordMessage = context.strings.weakStrength;
        passwordMessageType = TextInputComponentMessageType.alert;
      }
    }

    String? confirmPasswordMessage;
    TextInputComponentMessageType confirmPasswordMessageType =
        TextInputComponentMessageType.helper;

    final shownPasswordsMatch = _shownPasswordsMatch;
    if (_passwordInInputConfirmationBox.isNotEmpty &&
        _passwordInInputBox.isNotEmpty &&
        shownPasswordsMatch != null) {
      if (shownPasswordsMatch) {
        confirmPasswordMessage = context.strings.passwordsMatch;
        confirmPasswordMessageType = TextInputComponentMessageType.success;
      } else {
        confirmPasswordMessage = context.strings.passwordsDontMatch;
        confirmPasswordMessageType = TextInputComponentMessageType.error;
      }
    }

    return AutofillGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Visibility(
            visible: false,
            maintainState: true,
            child: TextFormField(
              autofillHints: const [AutofillHints.email],
              autocorrect: false,
              keyboardType: TextInputType.emailAddress,
              initialValue: email,
              textInputAction: TextInputAction.next,
            ),
          ),
          TextInputComponent(
            key: _passwordFieldKey,
            label: context.strings.password,
            hintText: context.strings.password,
            controller: _passwordController1,
            focusNode: _passwordFocusNode,
            groupId: _passwordController1,
            textInputAction: TextInputAction.next,
            isPasswordInput: true,
            isRequired: true,
            autocorrect: false,
            autofillHints: const [AutofillHints.newPassword],
            message: passwordMessage,
            messageType: passwordMessageType,
            onChanged: (password) {
              _passwordStrengthTimer?.cancel();
              setState(() {
                _passwordInInputBox = password;
                _passwordStrength = estimatePasswordStrength(password);
                _isPasswordValid =
                    _passwordStrength >= kMildPasswordStrengthThreshold;
                _passwordsMatch =
                    _passwordInInputBox == _passwordInInputConfirmationBox;
                if (password.isEmpty) _shownPasswordStrength = null;
                if (_shownPasswordsMatch != null) {
                  _shownPasswordsMatch = _passwordsMatch;
                }
              });
              if (password.isEmpty) return;
              _passwordStrengthTimer = Timer(const Duration(seconds: 1), () {
                if (mounted) {
                  setState(() {
                    _shownPasswordStrength = _passwordStrength;
                  });
                  _revealMessage(_passwordFieldKey, _passwordFocusNode);
                }
              });
            },
          ),
          const SizedBox(height: 16),
          TextInputComponent(
            key: _confirmPasswordFieldKey,
            label: context.strings.confirmPassword,
            hintText: context.strings.confirmPassword,
            controller: _passwordController2,
            focusNode: _confirmPasswordFocusNode,
            groupId: _passwordController1,
            isPasswordInput: true,
            isRequired: true,
            autocorrect: false,
            autofillHints: const [],
            finishAutofillContextOnEditingComplete: true,
            shouldUnfocusOnClearOrSubmit: true,
            onSubmit: _passwordsMatch && _isPasswordValid
                ? (_) => _submitPassword()
                : null,
            message: confirmPasswordMessage,
            messageType: confirmPasswordMessageType,
            onChanged: (cnfPassword) {
              _confirmPasswordTimer?.cancel();
              setState(() {
                _passwordInInputConfirmationBox = cnfPassword;
                if (cnfPassword.isEmpty) _shownPasswordsMatch = null;
                if (_passwordInInputBox.isNotEmpty) {
                  _passwordsMatch =
                      _passwordInInputBox == _passwordInInputConfirmationBox;
                }
              });
              if (cnfPassword.isEmpty) return;
              _confirmPasswordTimer = Timer(const Duration(seconds: 1), () {
                if (mounted) {
                  setState(() {
                    _shownPasswordsMatch = _passwordsMatch;
                  });
                  _revealMessage(
                    _confirmPasswordFieldKey,
                    _confirmPasswordFocusNode,
                  );
                }
              });
            },
          ),
        ],
      ),
    );
  }

  void _revealMessage(GlobalKey fieldKey, FocusNode focusNode) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final fieldContext = fieldKey.currentContext;
      if (fieldContext == null || !focusNode.hasFocus) return;
      unawaited(
        Scrollable.ensureVisible(
          fieldContext,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ),
      );
    });
  }

  void _updatePassword() async {
    final logOutFromOthers = await logOutFromOtherDevices(context);
    if (!mounted) return;
    final dialog = createProgressDialog(
      context,
      context.strings.generatingEncryptionKeys,
    );
    await dialog.show();
    try {
      await UserService.instance.changePassword(
        _passwordController1.text,
        logoutOtherDevices: logOutFromOthers,
      );
      await dialog.hide();
      if (widget.mode == PasswordEntryMode.reset) {
        Bus.instance.fire(SubscriptionPurchasedEvent());
      }
      if (!mounted) return;
      showShortToast(context, context.strings.passwordChangedSuccessfully);
      if (!mounted) return;
      Navigator.of(context).pop();
      if (widget.mode == PasswordEntryMode.reset) {
        if (!mounted) return;
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e, s) {
      _logger.severe("Failed to change password", e, s);
      await dialog.hide();
      if (!mounted) return;
      await showGenericErrorBottomSheet(context: context, error: e);
    }
  }

  Future<bool> logOutFromOtherDevices(BuildContext context) async {
    bool logOutFromOther = true;
    await showChoiceDialog(
      context,
      title: context.strings.signOutFromOtherDevices,
      body: context.strings.signOutOtherBody,
      isDismissible: false,
      firstButtonLabel: context.strings.signOutOtherDevices,
      firstButtonType: ButtonType.critical,
      firstButtonOnTap: () async {
        logOutFromOther = true;
      },
      secondButtonLabel: context.strings.doNotSignOut,
      secondButtonOnTap: () async {
        logOutFromOther = false;
      },
    );
    return logOutFromOther;
  }

  Future<void> _showRecoveryCodeDialog(String password) async {
    final dialog = createProgressDialog(
      context,
      context.strings.generatingEncryptionKeys,
    );
    await dialog.show();
    try {
      final result = await UserService.instance.generateKey(password);
      Configuration.instance.resetVolatilePassword();
      await dialog.hide();
      Future<void> onDone() async {
        final dialog = createProgressDialog(
          context,
          context.strings.pleaseWait,
        );
        await dialog.show();
        try {
          await UserService.instance.setAttributes(result);
          await dialog.hide();
          Configuration.instance.resetVolatilePassword();
          if (mounted) {
            await Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(
                builder: (BuildContext context) {
                  return getSubscriptionPage(isOnBoarding: true);
                },
              ),
              (route) => route.isFirst,
            );
          }
          Bus.instance.fire(AccountConfiguredEvent());
        } catch (e, s) {
          _logger.severe("Failed to configure account", e, s);
          await dialog.hide();
          if (!mounted) return;
          await showGenericErrorBottomSheet(context: context, error: e);
        }
      }

      if (!mounted) return;
      // ignore: unawaited_futures
      routeToPage(
        context,
        RecoveryKeyPage(
          result.recoveryKey,
          context.strings.next,
          onDone: onDone,
          isOnboarding: true,
        ),
      );
    } catch (e) {
      _logger.severe(e);
      await dialog.hide();
      if (!mounted) return;
      if (e == const AccountsError.keyDerivation()) {
        // ignore: unawaited_futures
        showAlertBottomSheet(
          context,
          title: context.strings.insecureDevice,
          message: context
              .strings
              .sorryWeCouldNotGenerateSecureKeysOnThisDevicennplease,
          assetPath: 'assets/warning-grey.png',
        );
      } else {
        await showGenericErrorBottomSheet(context: context, error: e);
      }
    }
  }
}
