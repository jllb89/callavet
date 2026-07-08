import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/environment.dart';
import '../../../core/router/route_observer.dart';

enum _HomeAiPhase { home, fadingOut, prompt }

const _composerPlaceholderText = 'escribir mensaje...';
const _composerTextStyle = TextStyle(
  color: Colors.white,
  fontSize: 14,
  fontFamily: 'ABCDiatype',
  fontWeight: FontWeight.w400,
  height: 1.25,
  letterSpacing: 0,
);
const _composerPlaceholderStyle = TextStyle(
  color: Color(0x52FFFFFF),
  fontSize: 14,
  fontFamily: 'ABCDiatype',
  fontWeight: FontWeight.w400,
  height: 1.25,
  letterSpacing: 0,
);

void _homeAiLog(String message) {
  debugPrint('[AIChat][Home] $message');
}

void _surveyHomeLog(String message) {
  debugPrint('[ConsultSurvey][HomeCard] $message');
}

class HomeV2Screen extends StatefulWidget {
  const HomeV2Screen({
    super.key,
    this.initialActiveConsultId,
    this.initialActiveConsultMode,
    this.initialActiveConsultVetName,
  });

  final String? initialActiveConsultId;
  final String? initialActiveConsultMode;
  final String? initialActiveConsultVetName;

  @override
  State<HomeV2Screen> createState() => _HomeV2ScreenState();
}

class _HomeV2ScreenState extends State<HomeV2Screen>
    with RouteAware, WidgetsBindingObserver {
  final _messageCtrl = TextEditingController();
  final _messageFocusNode = FocusNode();
  final _activeConsults = <_ActiveConsult>[];
  RealtimeChannel? _homeSessionsChannel;
  RealtimeChannel? _homeSurveysChannel;
  Timer? _homeRefreshDebounce;
  _PendingSurvey? _pendingSurvey;
  String _firstName = '';
  _HomeAiPhase _aiPhase = _HomeAiPhase.home;
  bool _homeVisible = false;
  bool _activeConsultsLoaded = false;
  bool _pendingSurveyLoaded = false;
  PageRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadFirstName();
    _seedInitialActiveConsult();
    unawaited(_loadActiveConsults());
    unawaited(_loadPendingSurveys());
    _startHomeRealtime();
    WidgetsBinding.instance.addPostFrameCallback((_) => _playHomeFade());
  }

  void _seedInitialActiveConsult() {
    final id = widget.initialActiveConsultId?.trim();
    if (id == null || id.isEmpty) return;
    final mode = widget.initialActiveConsultMode?.trim().toLowerCase();
    final consult = _ActiveConsult.fallback(
      id: id,
      mode: mode == 'video' ? 'video' : 'chat',
      vetName: widget.initialActiveConsultVetName,
    );
    _activeConsults
      ..clear()
      ..add(consult);
    _activeConsultsLoaded = true;
    _homeAiLog('seeded active consult from route id=$id mode=${consult.mode}');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && _route != route) {
      if (_route != null) mobileRouteObserver.unsubscribe(this);
      mobileRouteObserver.subscribe(this, route);
      _route = route;
    }
  }

  @override
  void didPopNext() {
    if (_aiPhase == _HomeAiPhase.home) _playHomeFade();
    unawaited(_refreshHomeActivity());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshHomeActivity());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    mobileRouteObserver.unsubscribe(this);
    _homeRefreshDebounce?.cancel();
    final channel = _homeSessionsChannel;
    if (channel != null) {
      Supabase.instance.client.removeChannel(channel);
    }
    final surveysChannel = _homeSurveysChannel;
    if (surveysChannel != null) {
      Supabase.instance.client.removeChannel(surveysChannel);
    }
    _messageCtrl.dispose();
    _messageFocusNode.dispose();
    super.dispose();
  }

  void _startHomeRealtime() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    final channel = Supabase.instance.client.channel('owner-home:$userId');
    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chat_sessions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => _scheduleHomeRefresh(),
        )
        .subscribe();
    _homeSessionsChannel = channel;

    final surveysChannel =
        Supabase.instance.client.channel('owner-home-surveys:$userId');
    surveysChannel
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'consult_surveys',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => _scheduleHomeRefresh(),
        )
        .subscribe();
    _homeSurveysChannel = surveysChannel;
  }

  void _scheduleHomeRefresh() {
    _homeRefreshDebounce?.cancel();
    _homeRefreshDebounce = Timer(const Duration(milliseconds: 350),
        () => unawaited(_refreshHomeActivity()));
  }

  Future<void> _refreshHomeActivity() async {
    if (!mounted) return;
    await Future.wait([
      _loadActiveConsults(),
      _loadPendingSurveys(),
    ]);
  }

  void _playHomeFade() {
    if (!mounted) return;
    setState(() => _homeVisible = false);
    Future<void>.delayed(const Duration(milliseconds: 16), () {
      if (!mounted) return;
      setState(() => _homeVisible = true);
    });
  }

  Future<void> _loadActiveConsults() async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      if (mounted) setState(() => _activeConsultsLoaded = true);
      return;
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client
          .getUrl(Uri.parse('${Environment.apiBaseUrl}/sessions?limit=20'));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      final rawBody = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) return;
      final decoded =
          rawBody.trim().isEmpty ? <String, dynamic>{} : jsonDecode(rawBody);
      final rows = _asList(_asMap(decoded)?['data']) ?? const [];
      final consults = rows
          .map(_asMap)
          .whereType<Map<String, dynamic>>()
          .map(_ActiveConsult.fromJson)
          .toList(growable: false);
      final active = consults
          .where((consult) => consult.isActive)
          .take(3)
          .toList(growable: false);
      final activeIds = active.map((consult) => consult.id).toSet();
      final inactiveIds = consults
          .where((consult) => !consult.isActive)
          .map((consult) => consult.id)
          .toSet();
      final preserved = _activeConsults.where((consult) {
        return consult.isActive &&
            !activeIds.contains(consult.id) &&
            !inactiveIds.contains(consult.id);
      });
      final merged = [...active, ...preserved].take(3).toList(growable: false);
      if (!mounted) return;
      setState(() {
        _activeConsults
          ..clear()
          ..addAll(merged);
        _activeConsultsLoaded = true;
      });
      _homeAiLog(
        'active consult load rows=${rows.length} active=${active.length} preserved=${merged.length - active.length} visible=${merged.length} statuses=${consults.map((consult) => '${consult.id}:${consult.status}:${consult.mode}').join(',')}',
      );
    } catch (_) {
      // Home should keep rendering even if session activity cannot load.
    } finally {
      client.close(force: true);
      if (mounted && !_activeConsultsLoaded) {
        setState(() => _activeConsultsLoaded = true);
      }
    }
  }

  Future<void> _loadPendingSurveys() async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      if (mounted) setState(() => _pendingSurveyLoaded = true);
      return;
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client
          .getUrl(Uri.parse('${Environment.apiBaseUrl}/me/surveys/pending'));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      final rawBody = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) return;
      final decoded =
          rawBody.trim().isEmpty ? <String, dynamic>{} : jsonDecode(rawBody);
      final rows = _asList(_asMap(decoded)?['data']) ?? const [];
      _PendingSurvey? pending;
      for (final row in rows) {
        final map = _asMap(row);
        if (map == null) continue;
        final survey = _PendingSurvey.fromJson(map);
        if (survey.sessionId.isNotEmpty) {
          pending = survey;
          break;
        }
      }
      _surveyHomeLog('pending load found=${pending != null}');
      if (!mounted) return;
      setState(() {
        _pendingSurvey = pending;
        _pendingSurveyLoaded = true;
      });
    } catch (error) {
      _surveyHomeLog('pending load failed: $error');
    } finally {
      client.close(force: true);
      if (mounted && !_pendingSurveyLoaded) {
        setState(() => _pendingSurveyLoaded = true);
      }
    }
  }

  Future<void> _answerPendingSurvey(
      _PendingSurvey survey, String answer) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) return;
    _surveyHomeLog(
        'pending answer sessionId=${survey.sessionId} answer=$answer');
    if (answer == 'now') {
      context.go('/chat/${Uri.encodeComponent(survey.sessionId)}?survey=true');
      return;
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(Uri.parse(
          '${Environment.apiBaseUrl}/sessions/${Uri.encodeComponent(survey.sessionId)}/survey/prompt-response'));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.add(utf8.encode(jsonEncode({'answer': answer})));
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode >= 200 && response.statusCode < 300 && mounted) {
        setState(() => _pendingSurvey = null);
      }
    } catch (error) {
      _surveyHomeLog('pending answer failed: $error');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _loadFirstName() async {
    final user = Supabase.instance.client.auth.currentUser;
    final fallback =
        _firstNameFrom(user?.userMetadata?['full_name']?.toString()) ??
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
    _homeAiLog(
        'enterAiMode requested phase=$_aiPhase textLength=${_messageCtrl.text.trim().length}');
    if (_aiPhase == _HomeAiPhase.prompt) {
      _homeAiLog('enterAiMode already prompt; focusing composer');
      _messageFocusNode.requestFocus();
      return;
    }
    if (_aiPhase == _HomeAiPhase.fadingOut) {
      _homeAiLog('enterAiMode ignored while fading out');
      return;
    }

    setState(() => _aiPhase = _HomeAiPhase.fadingOut);
    _homeAiLog('enterAiMode phase=fadingOut');
    await Future<void>.delayed(const Duration(milliseconds: 260));
    if (!mounted || _aiPhase != _HomeAiPhase.fadingOut) return;
    setState(() => _aiPhase = _HomeAiPhase.prompt);
    _homeAiLog('enterAiMode phase=prompt');
  }

  void _exitAiMode() {
    _homeAiLog('exitAiMode from phase=$_aiPhase');
    _messageFocusNode.unfocus();
    setState(() => _aiPhase = _HomeAiPhase.home);
    _playHomeFade();
  }

  void _useSuggestion(String text) {
    _homeAiLog(
        'suggestion selected length=${text.length} preview="${text.length > 80 ? '${text.substring(0, 80)}...' : text}"');
    _openAiChatWithText(text);
  }

  void _openAiChat() {
    final text = _messageCtrl.text.trim();
    _homeAiLog(
        'openAiChat requested phase=$_aiPhase textLength=${text.length}');
    if (text.isEmpty) {
      _homeAiLog('openAiChat empty text; staying in AI prompt mode');
      _enterAiMode();
      return;
    }
    _openAiChatWithText(text);
  }

  void _openAiChatWithText(String rawText) {
    final text = rawText.trim();
    if (text.isEmpty) return;
    _messageFocusNode.unfocus();
    _messageCtrl.clear();
    final query = Uri(queryParameters: {
      'message': text,
      'displayName': _displayName,
    }).query;
    _homeAiLog(
        'opening full AI chat route initialMessageLength=${text.length}');
    context.go('/chat/ai?$query');
  }

  String get _displayName => _firstName.isEmpty ? 'Jorge' : _firstName;

  @override
  Widget build(BuildContext context) {
    final displayName = _displayName;
    final hasActiveConsults =
        _activeConsultsLoaded && _activeConsults.isNotEmpty;
    final isPrompt = _aiPhase == _HomeAiPhase.prompt;
    final isAiActive = isPrompt;

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
          bottom: false,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            opacity: _homeVisible ? 1 : 0,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 24, 18, 0),
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
                    height: isAiActive ? 24 : 96,
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
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 332,
                    child: Text(
                      hasActiveConsults
                          ? 'Esta es tu actividad:'
                          : '¿Cómo podemos asistirte hoy?',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontFamily: 'ABCDiatype',
                        fontWeight: FontWeight.w400,
                        height: 1.10,
                      ),
                    ),
                  ),
                  const SizedBox(height: 30),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 320),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) {
                        final offsetAnimation = Tween<Offset>(
                          begin: const Offset(0, 0.025),
                          end: Offset.zero,
                        ).animate(animation);
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: offsetAnimation,
                            child: child,
                          ),
                        );
                      },
                      child: isPrompt
                          ? _AiSuggestionList(
                              key: const ValueKey('ai-prompt-suggestions'),
                              onSelected: _useSuggestion,
                            )
                          : _HomeDefaultSection(
                              key: const ValueKey('home-default-section'),
                              visible: _aiPhase == _HomeAiPhase.home,
                              pendingSurvey: _pendingSurvey,
                              pendingSurveyLoaded: _pendingSurveyLoaded,
                              activeConsults: _activeConsults,
                              activeConsultsLoaded: _activeConsultsLoaded,
                              onSurveyNow: (survey) =>
                                  _answerPendingSurvey(survey, 'now'),
                              onSurveyLater: (survey) =>
                                  _answerPendingSurvey(survey, 'later'),
                              onSurveyDismiss: (survey) =>
                                  _answerPendingSurvey(survey, 'dismiss'),
                              onConsultSelected: (consult) {
                                if (consult.mode == 'video') {
                                  context.go(
                                      '/video/${Uri.encodeComponent(consult.id)}');
                                } else {
                                  context.go(
                                      '/chat/${Uri.encodeComponent(consult.id)}');
                                }
                              },
                            ),
                    ),
                  ),
                  _MessageComposer(
                    controller: _messageCtrl,
                    focusNode: _messageFocusNode,
                    isPrompt: isPrompt,
                    onTap: _enterAiMode,
                    onSend: _openAiChat,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _terminalConsultStatuses = {
  'completed',
  'closed',
  'ended',
  'cancelled',
  'canceled',
  'expired',
  'failed',
  'finished',
  'forced_ended',
  'host_absent',
  'no_show',
  'released',
  'timed_out',
};

class _ActiveConsult {
  const _ActiveConsult({
    required this.id,
    required this.mode,
    required this.status,
    required this.vetName,
  });

  factory _ActiveConsult.fromJson(Map<String, dynamic> json) {
    return _ActiveConsult(
      id: json['id']?.toString() ?? '',
      mode: json['mode']?.toString().toLowerCase() ?? 'chat',
      status: json['status']?.toString().toLowerCase() ?? '',
      vetName: _cleanLabel(json['vet_name']) ??
          _cleanLabel(json['vetName']) ??
          'tu veterinario',
    );
  }

  factory _ActiveConsult.fallback({
    required String id,
    required String mode,
    String? vetName,
  }) {
    return _ActiveConsult(
      id: id,
      mode: mode,
      status: 'active',
      vetName: _cleanLabel(vetName) ?? 'tu veterinario',
    );
  }

  final String id;
  final String mode;
  final String status;
  final String vetName;

  bool get isActive =>
      id.isNotEmpty &&
      !_terminalConsultStatuses.contains(status) &&
      (mode == 'chat' || mode == 'video');
}

class _PendingSurvey {
  const _PendingSurvey({
    required this.id,
    required this.sessionId,
    required this.petName,
    required this.vetName,
  });

  factory _PendingSurvey.fromJson(Map<String, dynamic> json) {
    final session = _asMap(json['session']) ?? const <String, dynamic>{};
    return _PendingSurvey(
      id: json['id']?.toString() ?? '',
      sessionId: json['sessionId']?.toString() ?? '',
      petName: _cleanLabel(session['petName']) ?? 'tu caballo',
      vetName: _cleanLabel(session['vetName']) ?? 'tu veterinario',
    );
  }

  final String id;
  final String sessionId;
  final String petName;
  final String vetName;

  String get subtitle =>
      'Cuéntanos cómo fue la atención de $vetName para $petName.';
}

Map<String, dynamic>? _asMap(Object? value) {
  return value is Map
      ? value.map((key, val) => MapEntry(key.toString(), val))
      : null;
}

List<Object?>? _asList(Object? value) => value is List ? value : null;

String? _cleanLabel(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

String _shortLabel(String value, {required int maxLength}) {
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.length <= maxLength) return normalized;
  final first = normalized.split(' ').first.trim();
  if (first.isNotEmpty && first.length <= maxLength) return first;
  return normalized.substring(0, maxLength).trim();
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
                          colorFilter: const ColorFilter.mode(
                              Colors.white, BlendMode.srcIn),
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
                          colorFilter: const ColorFilter.mode(
                              Colors.white, BlendMode.srcIn),
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
  const _HomeDefaultSection({
    super.key,
    required this.visible,
    required this.pendingSurvey,
    required this.pendingSurveyLoaded,
    required this.activeConsults,
    required this.activeConsultsLoaded,
    required this.onSurveyNow,
    required this.onSurveyLater,
    required this.onSurveyDismiss,
    required this.onConsultSelected,
  });

  final bool visible;
  final _PendingSurvey? pendingSurvey;
  final bool pendingSurveyLoaded;
  final List<_ActiveConsult> activeConsults;
  final bool activeConsultsLoaded;
  final ValueChanged<_PendingSurvey> onSurveyNow;
  final ValueChanged<_PendingSurvey> onSurveyLater;
  final ValueChanged<_PendingSurvey> onSurveyDismiss;
  final ValueChanged<_ActiveConsult> onConsultSelected;

  @override
  Widget build(BuildContext context) {
    final showPendingSurvey = pendingSurveyLoaded && pendingSurvey != null;
    final showActiveConsults =
        activeConsultsLoaded && activeConsults.isNotEmpty;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      opacity: visible ? 1 : 0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _AiShortcut(),
          if (showPendingSurvey) ...[
            const SizedBox(height: 34),
            _PendingSurveyCard(
              survey: pendingSurvey!,
              onNow: () => onSurveyNow(pendingSurvey!),
              onLater: () => onSurveyLater(pendingSurvey!),
              onDismiss: () => onSurveyDismiss(pendingSurvey!),
            ),
          ],
          if (showActiveConsults) ...[
            const SizedBox(height: 50),
            const Text(
              'consultas activas:',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontFamily: 'ABCDiatype',
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 30),
            _ActiveConsultStrip(
              consults: activeConsults,
              onSelected: onConsultSelected,
            ),
          ],
        ],
      ),
    );
  }
}

class _PendingSurveyCard extends StatelessWidget {
  const _PendingSurveyCard({
    required this.survey,
    required this.onNow,
    required this.onLater,
    required this.onDismiss,
  });

  final _PendingSurvey survey;
  final VoidCallback onNow;
  final VoidCallback onLater;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Califica tu consulta',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontFamily: 'ABCDiatype',
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                survey.subtitle,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.68),
                  fontSize: 13,
                  fontFamily: 'ABCDiatype',
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _SurveyCardButton(
                      label: 'Calificar ahora', selected: true, onTap: onNow),
                  _SurveyCardButton(label: 'Más tarde', onTap: onLater),
                  _SurveyCardButton(label: 'Descartar', onTap: onDismiss),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SurveyCardButton extends StatelessWidget {
  const _SurveyCardButton({
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white,
            fontSize: 13,
            fontFamily: 'ABCDiatype',
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _ActiveConsultStrip extends StatelessWidget {
  const _ActiveConsultStrip({required this.consults, required this.onSelected});

  final List<_ActiveConsult> consults;
  final ValueChanged<_ActiveConsult> onSelected;

  @override
  Widget build(BuildContext context) {
    final consult = consults.first;
    return Align(
      alignment: Alignment.centerLeft,
      child: _ActiveConsultActionPill(
        consult: consult,
        onTap: () => onSelected(consult),
      ),
    );
  }
}

class _ActiveConsultActionPill extends StatelessWidget {
  const _ActiveConsultActionPill({required this.consult, required this.onTap});

  final _ActiveConsult consult;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isVideo = consult.mode == 'video';
    final vet = _shortLabel(consult.vetName, maxLength: 18);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 51,
        constraints: const BoxConstraints(minWidth: 220, maxWidth: 340),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(40),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isVideo ? Icons.videocam_rounded : Icons.chat_bubble_rounded,
              color: Colors.black,
              size: isVideo ? 17 : 16,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                'consulta activa con MVZ $vet',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 13,
                  fontFamily: 'ABCDiatype',
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
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

class _AiSuggestionList extends StatefulWidget {
  const _AiSuggestionList({super.key, required this.onSelected});

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
            padding: EdgeInsets.only(
                bottom: index == _suggestions.length - 1 ? 0 : 24),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
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
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isPrompt;
  final VoidCallback onTap;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.only(top: 8, bottom: 14 + bottomInset),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 46, maxHeight: 46),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white.withValues(alpha: 0.055)),
            ),
            child: Padding(
              padding:
                  const EdgeInsets.only(left: 18, right: 6, top: 3, bottom: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: isPrompt
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: ValueListenableBuilder<TextEditingValue>(
                              valueListenable: controller,
                              builder: (context, value, child) {
                                return Stack(
                                  alignment: Alignment.centerLeft,
                                  children: [
                                    if (value.text.isEmpty)
                                      const IgnorePointer(
                                        child: _ComposerPlaceholder(),
                                      ),
                                    TextField(
                                      controller: controller,
                                      focusNode: focusNode,
                                      cursorColor: Colors.white,
                                      cursorHeight: 16,
                                      keyboardType: TextInputType.multiline,
                                      textCapitalization:
                                          TextCapitalization.sentences,
                                      minLines: 1,
                                      maxLines: 1,
                                      textInputAction: TextInputAction.send,
                                      textAlignVertical:
                                          TextAlignVertical.center,
                                      onSubmitted: (_) => onSend(),
                                      style: _composerTextStyle,
                                      decoration: const InputDecoration(
                                        isCollapsed: true,
                                        isDense: true,
                                        contentPadding: EdgeInsets.zero,
                                        border: InputBorder.none,
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          )
                        : const Align(
                            alignment: Alignment.centerLeft,
                            child: _ComposerPlaceholder(),
                          ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 1),
                    child: IconButton.filled(
                      onPressed: isPrompt ? onSend : onTap,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        fixedSize: const Size(38, 38),
                      ),
                      icon: const Icon(Icons.arrow_upward_rounded, size: 19),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ComposerPlaceholder extends StatelessWidget {
  const _ComposerPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Text(
      _composerPlaceholderText,
      style: _composerPlaceholderStyle,
      textHeightBehavior: TextHeightBehavior(
        applyHeightToFirstAscent: false,
        applyHeightToLastDescent: false,
      ),
    );
  }
}
