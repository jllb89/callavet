import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

const bool _postLoginRoutingDebug = bool.fromEnvironment(
  'SUBSCRIPTION_FLOW_DEBUG',
  defaultValue: true,
);

void postLoginRouteLog(String message) {
  if (_postLoginRoutingDebug) {
    debugPrint('[PostLogin][Routing] $message');
  }
}

class PostLoginRoutingController {
  const PostLoginRoutingController._();

  static void routeTo(
    BuildContext context, {
    required String route,
    required String source,
    String? userId,
    String? reason,
  }) {
    postLoginRouteLog(
      '[$source] Routing userId=$userId to $route '
      '${reason == null || reason.isEmpty ? '' : 'reason=$reason'}',
    );
    context.go(route);
  }

  static void routeToSubscriptionGate(
    BuildContext context, {
    required String source,
    String? userId,
    String? reason,
  }) {
    routeTo(
      context,
      route: '/subscription-loader',
      source: source,
      userId: userId,
      reason: reason,
    );
  }
}