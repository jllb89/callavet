import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'route_observer.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/chat/presentation/vet_chat_screen.dart';
import '../../features/dashboard/presentation/vet_dashboard_screen.dart';
import '../../features/onboarding/presentation/splash_screen.dart';
import '../../features/video/presentation/vet_video_call_screen.dart';

class AppRouter {
  static final router = GoRouter(
    initialLocation: '/splash',
    observers: [vetRouteObserver],
    routes: [
      GoRoute(
        path: '/splash',
        name: 'splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/dashboard',
        name: 'dashboard',
        pageBuilder: (context, state) =>
            _noTransitionPage(state, const VetDashboardScreen()),
      ),
      GoRoute(
        path: '/video/:sessionId',
        name: 'videoCall',
        builder: (context, state) {
          final sessionId = state.pathParameters['sessionId'] ?? '';
          return VetVideoCallScreen(sessionId: sessionId);
        },
      ),
      GoRoute(
        path: '/chat/:sessionId',
        name: 'chat',
        pageBuilder: (context, state) {
          final sessionId = state.pathParameters['sessionId'] ?? '';
          final query = state.uri.queryParameters;
          return _noTransitionPage(
            state,
            VetChatScreen(
              sessionId: sessionId,
              initialMessage: query['message'],
              displayName: query['displayName'],
            ),
          );
        },
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Text('Not found: ${state.error?.toString() ?? 'unknown route'}'),
      ),
    ),
  );
}

Page<void> _noTransitionPage(GoRouterState state, Widget child) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        child,
    child: child,
  );
}
