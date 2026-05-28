import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum _HomeAiPhase { home, fadingOut, prompt }

class HomeV2Screen extends StatefulWidget {
  const HomeV2Screen({super.key});

  @override
  State<HomeV2Screen> createState() => _HomeV2ScreenState();
}

class _HomeV2ScreenState extends State<HomeV2Screen> {
  final _messageCtrl = TextEditingController();
  final _messageFocusNode = FocusNode();
  String _firstName = '';
  _HomeAiPhase _aiPhase = _HomeAiPhase.home;

  @override
  void initState() {
    super.initState();
    _loadFirstName();
  }

  @override
  void dispose() {
    _messageCtrl.dispose();
    _messageFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadFirstName() async {
    final user = Supabase.instance.client.auth.currentUser;
    final fallback = _firstNameFrom(user?.userMetadata?['full_name']?.toString()) ??
        _firstNameFrom(user?.email?.split('@').first);
    if (fallback != null && mounted) {
      setState(() => _firstName = fallback);
    }

    final userId = user?.id;
    if (userId == null || userId.isEmpty) return;

    try {
      final row = await Supabase.instance.client
          .from('users')
          .select('full_name')
          .eq('id', userId)
          .maybeSingle();
      final firstName = _firstNameFrom(row?['full_name']?.toString());
      if (firstName != null && mounted) {
        setState(() => _firstName = firstName);
      }
    } catch (_) {
      // Keep the metadata fallback; home must not block on profile fetch.
    }
  }

  String? _firstNameFrom(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed.split(RegExp(r'\s+')).first;
  }

  Future<void> _enterAiMode() async {
    if (_aiPhase == _HomeAiPhase.prompt) {
      _messageFocusNode.requestFocus();
      return;
    }
    if (_aiPhase == _HomeAiPhase.fadingOut) return;

    setState(() => _aiPhase = _HomeAiPhase.fadingOut);
    await Future<void>.delayed(const Duration(milliseconds: 260));
    if (!mounted || _aiPhase != _HomeAiPhase.fadingOut) return;
    setState(() => _aiPhase = _HomeAiPhase.prompt);
  }

  void _exitAiMode() {
    _messageFocusNode.unfocus();
    setState(() => _aiPhase = _HomeAiPhase.home);
  }

  void _useSuggestion(String text) {
    _messageCtrl.text = text;
    _messageCtrl.selection = TextSelection.collapsed(offset: text.length);
    _messageFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final displayName = _firstName.isEmpty ? 'Jorge' : _firstName;
    final isPrompt = _aiPhase == _HomeAiPhase.prompt;

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment(0.50, -0.00),
            end: Alignment(0.50, 1.00),
            colors: [Color(0xFF141417), Color(0xFF070707)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(32, 24, 32, 24 + bottomInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _HomeTopBar(
                  phase: _aiPhase,
                  onBack: _exitAiMode,
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 560),
                  curve: Curves.easeOutCubic,
                  height: isPrompt ? 24 : 96,
                ),
                Text(
                  '¡Hola, $displayName!',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontFamily: 'ABCDiatype',
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 8),
                const SizedBox(
                  width: 340,
                  child: Text(
                    '¿Cómo podemos asistirte hoy?',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 36,
                      fontFamily: 'ABCDiatype',
                      fontWeight: FontWeight.w400,
                      height: 1.02,
                    ),
                  ),
                ),
                const SizedBox(height: 34),
                Expanded(
                  child: isPrompt
                      ? _AiSuggestionList(onSelected: _useSuggestion)
                      : _HomeDefaultSection(visible: _aiPhase == _HomeAiPhase.home),
                ),
                _MessageComposer(
                  controller: _messageCtrl,
                  focusNode: _messageFocusNode,
                  isPrompt: isPrompt,
                  onTap: _enterAiMode,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeTopBar extends StatelessWidget {
  const _HomeTopBar({
    required this.phase,
    required this.onBack,
  });

  final _HomeAiPhase phase;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final showHomeChrome = phase == _HomeAiPhase.home;
    final showBack = phase == _HomeAiPhase.prompt;

    return SizedBox(
      height: 42,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedOpacity(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            opacity: showHomeChrome ? 1 : 0,
            child: IgnorePointer(
              ignoring: !showHomeChrome,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: GestureDetector(
                      onTap: () => context.go('/settings'),
                      child: SizedBox(
                        width: 34,
                        height: 34,
                        child: SvgPicture.asset(
                          'assets/icons/user.svg',
                          fit: BoxFit.contain,
                          colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                        ),
                      ),
                    ),
                  ),
                  SvgPicture.asset(
                    'assets/icons/homelogo.svg',
                    width: 91,
                    height: 18,
                    fit: BoxFit.contain,
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: () => context.go('/horse-care'),
                      child: SizedBox(
                        width: 50,
                        height: 30,
                        child: SvgPicture.asset(
                          'assets/icons/caballo.svg',
                          fit: BoxFit.contain,
                          colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            opacity: showBack ? 1 : 0,
            child: IgnorePointer(
              ignoring: !showBack,
              child: Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  onTap: onBack,
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: SvgPicture.asset(
                      'assets/icons/arrow-left.svg',
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeDefaultSection extends StatelessWidget {
  const _HomeDefaultSection({required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      opacity: visible ? 1 : 0,
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AiShortcut(),
          SizedBox(height: 76),
          _EventsEmptyState(),
        ],
      ),
    );
  }
}

class _AiShortcut extends StatelessWidget {
  const _AiShortcut();

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/icons/ai.svg',
      width: 26,
      height: 26,
    );
  }
}

class _EventsEmptyState extends StatelessWidget {
  const _EventsEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'No tienes eventos programados o activos.',
      style: TextStyle(
        color: Colors.white,
        fontSize: 10,
        fontFamily: 'ABCDiatype',
        fontWeight: FontWeight.w300,
        height: 2.40,
      ),
    );
  }
}

class _AiSuggestionList extends StatefulWidget {
  const _AiSuggestionList({required this.onSelected});

  final ValueChanged<String> onSelected;

  @override
  State<_AiSuggestionList> createState() => _AiSuggestionListState();
}

class _AiSuggestionListState extends State<_AiSuggestionList> {
  int _visibleCount = 0;

  static const _suggestions = [
    'necesito hablar con un veterinario',
    'quiero saber cuándo tengo que vacunar a mi caballo',
    'quiero ver el historial de consultas de mi caballo en la plataforma',
  ];

  @override
  void initState() {
    super.initState();
    _revealSuggestions();
  }

  Future<void> _revealSuggestions() async {
    await Future<void>.delayed(const Duration(milliseconds: 540));
    for (var i = 1; i <= _suggestions.length; i++) {
      if (!mounted) return;
      setState(() => _visibleCount = i);
      await Future<void>.delayed(const Duration(milliseconds: 135));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 38),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(_suggestions.length, (index) {
          final maxWidths = [309.0, 254.0, 306.0];
          final visible = _visibleCount > index;
          return Padding(
            padding: EdgeInsets.only(bottom: index == _suggestions.length - 1 ? 0 : 24),
            child: _SuggestionBubble(
              maxWidth: maxWidths[index],
              text: _suggestions[index],
              visible: visible,
              onTap: () => widget.onSelected(_suggestions[index]),
            ),
          );
        }),
      ),
    );
  }
}

class _SuggestionBubble extends StatelessWidget {
  const _SuggestionBubble({
    required this.maxWidth,
    required this.text,
    required this.visible,
    required this.onTap,
  });

  final double maxWidth;
  final String text;
  final bool visible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
      opacity: visible ? 1 : 0,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
        offset: visible ? Offset.zero : const Offset(0, 0.08),
        child: IgnorePointer(
          ignoring: !visible,
          child: Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: onTap,
              child: Container(
                constraints: BoxConstraints(maxWidth: maxWidth),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(40),
                ),
                child: Text(
                  text,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontFamily: 'ABCDiatype',
                    fontWeight: FontWeight.w400,
                    height: 1.22,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageComposer extends StatelessWidget {
  const _MessageComposer({
    required this.controller,
    required this.focusNode,
    required this.isPrompt,
    required this.onTap,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isPrompt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: FractionallySizedBox(
        widthFactor: 1.06,
        child: Container(
          height: 40,
          padding: const EdgeInsets.only(left: 20, right: 14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(40),
          ),
          child: Row(
            children: [
              Expanded(
                child: isPrompt
                    ? TextField(
                        controller: controller,
                        focusNode: focusNode,
                        cursorColor: Colors.white,
                        minLines: 1,
                        maxLines: 1,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontFamily: 'ABCDiatype',
                          fontWeight: FontWeight.w500,
                        ),
                        decoration: InputDecoration(
                          isCollapsed: true,
                          border: InputBorder.none,
                          hintText: 'escribir mensaje...',
                          hintStyle: TextStyle(
                            color: Colors.white.withValues(alpha: 0.30),
                            fontSize: 13,
                            fontFamily: 'ABCDiatype',
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      )
                    : Text(
                        'escribir mensaje...',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.30),
                          fontSize: 13,
                          fontFamily: 'ABCDiatype',
                          fontWeight: FontWeight.w500,
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              SvgPicture.asset(
                'assets/icons/rightup.svg',
                width: 17,
                height: 17,
              ),
            ],
          ),
        ),
      ),
    );
  }
}