import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/login_screen.dart';
import '../../features/chat/presentation/vet_chat_screen.dart';
import '../../features/dashboard/presentation/vet_dashboard_screen.dart';
import '../../features/onboarding/presentation/splash_screen.dart';
import '../../features/video/presentation/vet_video_call_screen.dart';

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
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/dashboard',
        name: 'dashboard',
        builder: (context, state) => const VetDashboardScreen(),
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
        builder: (context, state) {
          final sessionId = state.pathParameters['sessionId'] ?? '';
          return VetChatScreen(sessionId: sessionId);
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
