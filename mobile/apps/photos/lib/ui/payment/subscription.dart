import "dart:async";

import 'package:flutter/material.dart';
import 'package:photos/core/configuration.dart';
import "package:photos/service_locator.dart";
import "package:photos/services/account/user_service.dart";
import "package:photos/ui/account/referral_source_page.dart";
import "package:photos/ui/payment/store_subscription_page.dart";
import 'package:photos/ui/payment/stripe_subscription_page.dart';

StatefulWidget getSubscriptionPage({bool isOnBoarding = false}) {
  if (updateService.isIndependentFlavor()) {
    return StripeSubscriptionPage(isOnboarding: isOnBoarding);
  }
  if (flagService.enableStripe && _isUserCreatedPostStripeSupport()) {
    return StripeSubscriptionPage(isOnboarding: isOnBoarding);
  } else {
    return StoreSubscriptionPage(isOnboarding: isOnBoarding);
  }
}

void closeOnboardingSubscription(BuildContext context) {
  final navigator = Navigator.of(context);
  if (!UserService.instance.shouldAskReferralSource) {
    navigator.popUntil(
      (route) => route.isFirst || ReferralSourcePage.isRoute(route),
    );
    return;
  }
  unawaited(UserService.instance.setShouldAskReferralSource(false));
  unawaited(
    navigator.pushAndRemoveUntil(
      ReferralSourcePage.route(),
      (route) => route.isFirst,
    ),
  );
}

// Older users may have an active Play/App Store subscription.
bool _isUserCreatedPostStripeSupport() {
  return Configuration.instance.getUserID()! > 1580559962386460;
}
