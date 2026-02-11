import 'package:flutter/material.dart';
import 'package:flutter_phoenix/flutter_phoenix.dart';

class UserSettingsScreen extends StatelessWidget {
  const UserSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('User Settings')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('User settings placeholder'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Phoenix.rebirth(context),
              child: const Text('Restart app'),
            ),
          ],
        ),
      ),
    );
  }
}
