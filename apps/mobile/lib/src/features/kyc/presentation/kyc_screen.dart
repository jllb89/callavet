import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class KycScreen extends StatelessWidget {
  const KycScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('KYC')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('User KYC placeholder'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => context.go('/horse-kyc'),
              child: const Text('Continue to Horse KYC'),
            ),
          ],
        ),
      ),
    );
  }
}
