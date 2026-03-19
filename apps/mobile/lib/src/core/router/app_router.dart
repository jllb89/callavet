import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../navigation/post_login_routing_controller.dart';

import '../../features/auth/presentation/login_screen.dart';
import '../../features/chat/presentation/chat_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/horse_care/presentation/horse_care_screen.dart';
import '../../features/horse_kyc/presentation/horse_kyc_screen.dart';
import '../../features/kyc/presentation/kyc_screen.dart';
import '../../features/onboarding/presentation/onboarding_screen.dart';
import '../../features/onboarding/presentation/splash_screen.dart';
import '../../features/subscriptions/presentation/subscription_plans_screen.dart';
import '../../features/user_settings/presentation/user_settings_screen.dart';

class AppRouter {
  static final router = GoRouter(
    initialLocation: '/splash',
    routes: [
      GoRoute(
        path: '/splash',
        name: 'splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        name: 'onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/kyc',
        name: 'kyc',
        builder: (context, state) {
          final startAt = state.uri.queryParameters['start'] ?? 'intro';
          return KycScreen(startAt: startAt);
        },
      ),
      GoRoute(
        path: '/horse-kyc',
        name: 'horseKyc',
        builder: (context, state) => const HorseKycScreen(),
      ),
      GoRoute(
        path: '/subscription-loader',
        name: 'subscriptionLoader',
        builder: (context, state) {
          final horses = int.tryParse(state.uri.queryParameters['horses'] ?? '');
          postLoginRouteLog(
            'Router entered /subscription-loader uri=${state.uri} horses=$horses',
          );
          return SubscriptionPlansLoaderScreen(horsesTarget: horses);
        },
      ),
      GoRoute(
        path: '/subscription-plans',
        name: 'subscriptionPlans',
        builder: (context, state) {
          final recommended = state.uri.queryParameters['recommended'];
          postLoginRouteLog(
            'Router entered /subscription-plans uri=${state.uri} '
            'recommended=$recommended',
          );
          return SubscriptionPlansScreen(
            recommendedCode: recommended,
          );
        },
      ),
      GoRoute(
        path: '/home',
        name: 'home',
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: '/chat/:sessionId',
        name: 'chat',
        builder: (context, state) {
          final sessionId = state.pathParameters['sessionId'] ?? '';
          return ChatScreen(sessionId: sessionId);
        },
      ),
      GoRoute(
        path: '/settings',
        name: 'settings',
        builder: (context, state) => const UserSettingsScreen(),
      ),
      GoRoute(
        path: '/horse-care',
        name: 'horseCare',
        builder: (context, state) => const HorseCareScreen(),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Text('Not found: ${state.error?.toString() ?? 'unknown route'}'),
      ),
    ),
  );
}
