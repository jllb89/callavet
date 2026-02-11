import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Home hub placeholder'),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => context.go('/chat/demo-session'),
            child: const Text('Open Chat'),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => context.go('/horse-care'),
            child: const Text('Horse Care'),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => context.go('/settings'),
            child: const Text('User Settings'),
          ),
        ],
      ),
    );
  }
}
