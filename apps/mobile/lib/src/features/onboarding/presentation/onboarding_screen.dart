import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pageController = PageController();
  int _pageIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101010),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final viewportHeight = constraints.maxHeight;
              const ctaLabels = [
                'así funciona',
                'cuidado continuo',
                'úsalo para',
                'qué sigue',
              ];
              final ctaText = ctaLabels[_pageIndex.clamp(0, ctaLabels.length - 1)];
              return Column(
                children: [
                  // Top bar
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IgnorePointer(
                        ignoring: _pageIndex == 0,
                        child: Opacity(
                          opacity: _pageIndex == 0 ? 0 : 1,
                          child: TextButton(
                            onPressed: () {
                              if (_pageIndex > 0) {
                                _pageController.animateToPage(
                                  _pageIndex - 1,
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeOut,
                                );
                              } else {
                                context.go('/home');
                              }
                            },
                            style: TextButton.styleFrom(foregroundColor: Colors.white),
                            child: const Text(
                              'atrás',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                      TextButton(
                            onPressed: () => context.go('/kyc'),
                        style: TextButton.styleFrom(foregroundColor: Colors.white),
                        child: const Text(
                          'saltar',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),

                  // Paged content
                  Expanded(
                    child: PageView(
                      controller: _pageController,
                      onPageChanged: (i) => setState(() => _pageIndex = i),
                      children: [
                        _FirstPage(
                          viewportHeight: viewportHeight,
                          isActive: _pageIndex == 0,
                        ),
                        _SecondPage(
                          viewportHeight: viewportHeight,
                          isActive: _pageIndex == 1,
                        ),
                        _ThirdPage(
                          viewportHeight: viewportHeight,
                          isActive: _pageIndex == 2,
                        ),
                        _UseCasesPage(
                          viewportHeight: viewportHeight,
                          isActive: _pageIndex == 3,
                        ),
                      ],
                    ),
                  ),

                  // Bottom row with dots and CTA kept consistent
                  Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Row(
                      children: [
                        _Dots(activeIndex: _pageIndex, count: 4),
                        const Spacer(),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              ctaText,
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(width: 12),
                            GestureDetector(
                              onTap: () {
                                final nextPage = _pageIndex + 1;
                                if (nextPage < 4) {
                                  _pageController.animateToPage(
                                    nextPage,
                                    duration: const Duration(milliseconds: 300),
                                    curve: Curves.easeOut,
                                  );
                                } else {
                                  context.go('/kyc');
                                }
                              },
                              behavior: HitTestBehavior.opaque,
                              child: SvgPicture.asset(
                                'assets/icons/continue.svg',
                                width: 48,
                                height: 48,
                                colorFilter:
                                    const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.activeIndex, required this.count});

  final int activeIndex;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(count, (index) {
        final isActive = index == activeIndex;
        return Padding(
          padding: EdgeInsets.only(right: index == count - 1 ? 0 : 4),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            width: isActive ? 17 : 4,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(isActive ? 5 : 2),
              // slight transparency on inactive to mimic original appearance
              boxShadow: isActive
                  ? null
                  : const [
                      BoxShadow(
                        color: Color(0x4DFFFFFF),
                        blurRadius: 0,
                        spreadRadius: 0,
                      ),
                    ],
            ),
          ),
        );
      }),
    );
  }
}

class _FirstPage extends StatefulWidget {
  const _FirstPage({required this.viewportHeight, required this.isActive});

  final double viewportHeight;
  final bool isActive;

  @override
  State<_FirstPage> createState() => _FirstPageState();
}

class _FirstPageState extends State<_FirstPage> {
  bool _showMedia = false;
  bool _showText = false;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _startAnimation();
  }

  @override
  void didUpdateWidget(covariant _FirstPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _startAnimation();
    } else if (!widget.isActive && oldWidget.isActive) {
      _resetAnimation();
    }
  }

  void _resetAnimation() {
    if (!_showMedia && !_showText) return;
    setState(() {
      _showMedia = false;
      _showText = false;
    });
  }

  void _startAnimation() {
    setState(() => _showMedia = true);
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted || !widget.isActive) return;
      setState(() => _showText = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Hero image
          AnimatedOpacity(
            duration: const Duration(milliseconds: 1000),
            curve: Curves.easeOut,
            opacity: _showMedia ? 1 : 0,
            child: Padding(
              padding: const EdgeInsets.only(top: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(40),
                child: AspectRatio(
                  aspectRatio: 414 / 491,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.asset(
                        'assets/images/onboarding/rectangle_2.png',
                        fit: BoxFit.cover,
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x00101010), Color(0xFF101010)],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 32),

          // Copy block
          AnimatedOpacity(
            duration: const Duration(milliseconds: 550),
            curve: Curves.easeOut,
            opacity: _showText ? 1 : 0,
            child: SizedBox(
              width: 353,
              child: Text.rich(
                TextSpan(
                  children: const [
                    TextSpan(
                      text: 'Cuando algo no está bien, esperar cuesta caro.\n',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                        height: 1.10,
                      ),
                    ),
                    TextSpan(text: '\n'),
                    TextSpan(
                      text:
                          'Un traslado innecesario, una mala decisión o una duda sin resolver puede afectar la salud y el rendimiento de tu caballo.',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w300,
                        height: 1.83,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 48),
        ],
      ),
    );
  }
}

class _UseCasesPage extends StatefulWidget {
  const _UseCasesPage({required this.viewportHeight, required this.isActive});

  final double viewportHeight;
  final bool isActive;

  @override
  State<_UseCasesPage> createState() => _UseCasesPageState();
}

class _UseCasesPageState extends State<_UseCasesPage> {
  bool _showMedia = false;
  bool _showText = false;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _startAnimation();
  }

  @override
  void didUpdateWidget(covariant _UseCasesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _startAnimation();
    } else if (!widget.isActive && oldWidget.isActive) {
      _resetAnimation();
    }
  }

  void _resetAnimation() {
    if (!_showMedia && !_showText) return;
    setState(() {
      _showMedia = false;
      _showText = false;
    });
  }

  void _startAnimation() {
    setState(() => _showMedia = true);
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted || !widget.isActive) return;
      setState(() => _showText = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedOpacity(
            duration: const Duration(milliseconds: 1000),
            curve: Curves.easeOut,
            opacity: _showMedia ? 1 : 0,
            child: Padding(
              padding: const EdgeInsets.only(top: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(40),
                child: AspectRatio(
                  aspectRatio: 414 / 491,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.asset(
                        'assets/images/onboarding/rectangle_2.png',
                        fit: BoxFit.cover,
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x00101010), Color(0xFF101010)],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 32),

          AnimatedOpacity(
            duration: const Duration(milliseconds: 550),
            curve: Curves.easeOut,
            opacity: _showText ? 1 : 0,
            child: SizedBox(
              width: 353,
              child: Text.rich(
                TextSpan(
                  children: const [
                    TextSpan(
                      text: 'Úsalo para…\n',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                        height: 1.10,
                      ),
                    ),
                    TextSpan(text: '\n'),
                    TextSpan(
                      text:
                          'Dudas rápidas.\nSeguimiento de salud de tu caballo o cuadra.\nRevisión por cámara.\nEmergencias graves → derivación en clínica física o consulta presencial.',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w300,
                        height: 1.83,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 48),
        ],
      ),
    );
  }
}

class _SecondPage extends StatefulWidget {
  const _SecondPage({required this.viewportHeight, required this.isActive});

  final double viewportHeight;
  final bool isActive;

  @override
  State<_SecondPage> createState() => _SecondPageState();
}

class _SecondPageState extends State<_SecondPage> {
  bool _showMedia = false;
  bool _showText = false;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _startAnimation();
  }

  @override
  void didUpdateWidget(covariant _SecondPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _startAnimation();
    } else if (!widget.isActive && oldWidget.isActive) {
      _resetAnimation();
    }
  }

  void _resetAnimation() {
    if (!_showMedia && !_showText) return;
    setState(() {
      _showMedia = false;
      _showText = false;
    });
  }

  void _startAnimation() {
    setState(() => _showMedia = true);
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted || !widget.isActive) return;
      setState(() => _showText = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Chat area rendered from SVG asset for accurate layout
          AnimatedOpacity(
            duration: const Duration(milliseconds: 1000),
            curve: Curves.easeOut,
            opacity: _showMedia ? 1 : 0,
            child: SizedBox(
              height: 240,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: SvgPicture.asset(
                      'assets/icons/Group 1827.svg',
                      width: 320,
                      height: 230,
                      fit: BoxFit.contain,
                    ),
                  ),
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x33101010),
                            Color(0x8A101010),
                            Color(0xFF101010),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 72),

          // "Así funciona" block with inline icons
          AnimatedOpacity(
            duration: const Duration(milliseconds: 550),
            curve: Curves.easeOut,
            opacity: _showText ? 1 : 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: LayoutBuilder(
                builder: (context, boxConstraints) {
                  final blockWidth = boxConstraints.maxWidth * 0.9;
                  return SizedBox(
                    width: blockWidth,
                    height: 250,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: 0,
                          top: 0,
                          child: SizedBox(
                            width: blockWidth,
                            child: const Text(
                              'Así funciona Call a Vet.',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w500,
                                height: 1.10,
                              ),
                            ),
                          ),
                        ),
                        // Icons aligned with each subsection
                        Positioned(
                          left: 0,
                          top: 42,
                          child: SvgPicture.asset(
                            'assets/icons/f1 1.svg',
                            width: 16,
                            height: 16,
                            colorFilter:
                                const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          top: 118,
                          child: SvgPicture.asset(
                            'assets/icons/f3 1.svg',
                            width: 16,
                            height: 16,
                            colorFilter:
                                const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          top: 194,
                          child: SvgPicture.asset(
                            'assets/icons/f6 1.svg',
                            width: 16,
                            height: 16,
                            colorFilter:
                                const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                          ),
                        ),
                        Positioned(
                          left: 33,
                          top: 38,
                          child: SizedBox(
                            width: blockWidth - 24,
                            child: const Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: 'Cuéntanos el caso\n',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      height: 1.4,
                                    ),
                                  ),
                                  TextSpan(
                                    text:
                                        'Escribe lo que pasa. Nuestro asistente hace 2–3 preguntas clave para entender mejor.\n',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w300,
                                      height: 1.6,
                                    ),
                                  ),
                                  TextSpan(
                                    text: '\nConéctate con un vet\n',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      height: 1.4,
                                    ),
                                  ),
                                  TextSpan(
                                    text:
                                        'Te sugerimos chat o video según el caso. Pagas y entras a la consulta.\n',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w300,
                                      height: 1.6,
                                    ),
                                  ),
                                  TextSpan(
                                    text: '\nRecibe un plan personalizado\n',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      height: 1.4,
                                    ),
                                  ),
                                  TextSpan(
                                    text:
                                        'Al terminar, te compartimos un plan de cuidado propuesto con próximos pasos.',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w300,
                                      height: 1.6,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _ThirdPage extends StatefulWidget {
  const _ThirdPage({required this.viewportHeight, required this.isActive});

  final double viewportHeight;
  final bool isActive;

  @override
  State<_ThirdPage> createState() => _ThirdPageState();
}

class _ThirdPageState extends State<_ThirdPage> {
  bool _showMedia = false;
  bool _showText = false;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _startAnimation();
  }

  @override
  void didUpdateWidget(covariant _ThirdPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _startAnimation();
    } else if (!widget.isActive && oldWidget.isActive) {
      _resetAnimation();
    }
  }

  void _resetAnimation() {
    if (!_showMedia && !_showText) return;
    setState(() {
      _showMedia = false;
      _showText = false;
    });
  }

  void _startAnimation() {
    setState(() => _showMedia = true);
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted || !widget.isActive) return;
      setState(() => _showText = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, boxConstraints) {
        final blockWidth = boxConstraints.maxWidth * 0.9;
        final horizontalInset = (boxConstraints.maxWidth - blockWidth) / 2;
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 620,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 1000),
                      curve: Curves.easeOut,
                      opacity: _showMedia ? 1 : 0,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Align(
                            alignment: Alignment.topCenter,
                            child: SvgPicture.asset(
                              'assets/icons/rueda.svg',
                              width: 360,
                              height: 620,
                              fit: BoxFit.contain,
                            ),
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            height: 600,
                            child: const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Color(0x00101010),
                                    Color(0x8A101010),
                                    Color(0xFF101010),
                                    Color(0xFF101010),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: horizontalInset,
                      right: horizontalInset,
                      bottom: 48,
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 550),
                        curve: Curves.easeOut,
                        opacity: _showText ? 1 : 0,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            SizedBox(
                              width: 351,
                              child: Text(
                                'Cuidado continuo. No solo consultas.',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w500,
                                  height: 1.10,
                                ),
                              ),
                            ),
                            SizedBox(height: 6),
                            SizedBox(
                              width: 326,
                              child: Text(
                                '\nChats y videos incluidos cada mes\n\nPlanes de cuidado gratuitos por caballo\n\nHistorial médico y seguimiento\n\nSin contratos, cancela cuando quieras',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w300,
                                  height: 1.83,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.icon, required this.title, required this.body});

  final String icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SvgPicture.asset(
          icon,
          width: 18,
          height: 18,
          colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$title\n',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    height: 1.47,
                  ),
                ),
                TextSpan(
                  text: body,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w300,
                    height: 1.83,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
