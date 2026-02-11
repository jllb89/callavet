import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  bool _showContent = false;
  bool _fadeInComplete = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
    );
    // Fade from black over the hero image
    Future.delayed(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() => _fadeInComplete = true);
    });
    Future.delayed(const Duration(milliseconds: 2200), () {
      if (!mounted) return;
      setState(() => _showContent = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              image: DecorationImage(
                image: AssetImage('assets/images/onboarding/rectangle_1.png'),
                fit: BoxFit.cover,
              ),
            ),
          ),
          AnimatedOpacity(
            opacity: _fadeInComplete ? 0 : 1,
            duration: const Duration(milliseconds: 600),
            child: Container(color: const Color(0xFF101010)),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Top-right login (appears after delay)
                  Row(
                    children: [
                      const Spacer(),
                      AnimatedOpacity(
                        opacity: _showContent ? 1 : 0,
                        duration: const Duration(milliseconds: 300),
                        child: Container(
                          height: 38,
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(33.5),
                          ),
                          child: Center(
                            child: Text(
                              'iniciar sesión',
                              style: const TextStyle(
                                color: Colors.black,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const Spacer(),

                  // Centered logo above tagline
                  Center(
                    child: Column(
                      children: [
                        Image.asset(
                          'assets/icons/call_a_vet.png',
                          width: 148,
                          height: 40,
                          fit: BoxFit.contain,
                        ),
                        const SizedBox(height: 16),
                        AnimatedOpacity(
                          opacity: _showContent ? 1 : 0,
                          duration: const Duration(milliseconds: 300),
                          child: SizedBox(
                            width: 312,
                            child: Text(
                              'atención veterinaria especializada para tu caballo en minutos.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Bottom-right CTA with icon (appears after delay)
                  Row(
                    children: [
                      const Spacer(),
                      AnimatedOpacity(
                        opacity: _showContent ? 1 : 0,
                        duration: const Duration(milliseconds: 300),
                        child: GestureDetector(
                          onTap: () => context.go('/onboarding'),
                          behavior: HitTestBehavior.opaque,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              SizedBox(
                                height: 45,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    const Text(
                                      'empezar',
                                      textAlign: TextAlign.right,
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    SvgPicture.asset(
                                      'assets/icons/continue.svg',
                                      width: 48,
                                      height: 48,
                                      colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}