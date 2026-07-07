import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/environment.dart';
import '../../../core/router/route_observer.dart';

void _vetDashboardRoadmapLog(String message) {
  debugPrint('[VideoRoadmap][VetDashboard] $message');
}

class VetDashboardScreen extends StatefulWidget {
  const VetDashboardScreen({super.key});

  @override
  State<VetDashboardScreen> createState() => _VetDashboardScreenState();
}

class _VetDashboardScreenState extends State<VetDashboardScreen>
    with WidgetsBindingObserver, RouteAware {
  static const _dashboardRealtimeTables = <String>[
    'chat_sessions',
    'appointments',
    'video_session_lifecycle',
  ];

  bool _showProfile = false;
  bool _availableNow = true;
  final Set<String> _endingConsultIds = <String>{};
  final List<RealtimeChannel> _dashboardRealtimeChannels = <RealtimeChannel>[];
  RealtimeChannel? _dashboardBroadcastChannel;
  String? _dashboardBroadcastTopic;
  Timer? _dashboardRefreshDebounce;
  late Future<_VetProfileBundle> _profileBundleFuture;
  bool _dashboardVisible = false;
  PageRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _profileBundleFuture = _loadProfileBundle();
    _startDashboardRealtime();
    WidgetsBinding.instance.addPostFrameCallback((_) => _playDashboardFade());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && _route != route) {
      if (_route != null) vetRouteObserver.unsubscribe(this);
      vetRouteObserver.subscribe(this, route);
      _route = route;
    }
  }

  @override
  void didPopNext() {
    if (!_showProfile) _playDashboardFade();
  }

  @override
  void dispose() {
    vetRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _dashboardRefreshDebounce?.cancel();
    _removeDashboardBroadcast();
    _removeDashboardRealtime();
    super.dispose();
  }

  void _playDashboardFade() {
    if (!mounted) return;
    setState(() => _dashboardVisible = false);
    Future<void>.delayed(const Duration(milliseconds: 16), () {
      if (!mounted) return;
      setState(() => _dashboardVisible = true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startDashboardRealtime();
      _profileBundleFuture
          .then((bundle) => _startDashboardBroadcast(bundle.profile.id));
      _refreshDashboardQueue();
    }
  }

  Future<_VetProfileBundle> _loadProfileBundle() async {
    final profileResponse = await _getGatewayJson('/vets/me/profile');
    final specialtiesResponse = await _getGatewayJson('/vets/specialties');
    final queueResponse = await _getGatewayJson('/vets/me/queue');
    final specialties = _asList(specialtiesResponse['data'])
            ?.map(_asMap)
            .whereType<Map<String, dynamic>>()
            .map(_VetSpecialty.fromJson)
            .where((specialty) => specialty.isActive)
            .toList() ??
        const <_VetSpecialty>[];
    final profile = _VetProfile.fromJson(profileResponse);
    _startDashboardBroadcast(profile.id);
    return _VetProfileBundle(
      profile: profile,
      specialties: specialties,
      queue: _VetQueue.fromJson(queueResponse),
    );
  }

  Future<_VetProfileBundle> _loadQueueIntoBundle(
      Future<_VetProfileBundle> currentBundleFuture) async {
    try {
      final bundle = await currentBundleFuture;
      _startDashboardBroadcast(bundle.profile.id);
      final queueResponse = await _getGatewayJson('/vets/me/queue');
      return bundle.copyWith(queue: _VetQueue.fromJson(queueResponse));
    } catch (_) {
      return _loadProfileBundle();
    }
  }

  void _refreshDashboardQueue() {
    if (!mounted) return;
    final currentBundleFuture = _profileBundleFuture;
    setState(() {
      _profileBundleFuture = _loadQueueIntoBundle(currentBundleFuture);
    });
  }

  void _scheduleDashboardRefresh() {
    _dashboardRefreshDebounce?.cancel();
    _dashboardRefreshDebounce =
        Timer(const Duration(milliseconds: 650), _refreshDashboardQueue);
  }

  void _startDashboardRealtime() {
    if (_dashboardRealtimeChannels.isNotEmpty) return;
    final client = Supabase.instance.client;
    for (final table in _dashboardRealtimeTables) {
      final channel = client.channel('vet-dashboard:$table');
      channel
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: table,
            callback: (_) => _scheduleDashboardRefresh(),
          )
          .subscribe();
      _dashboardRealtimeChannels.add(channel);
    }
  }

  void _startDashboardBroadcast(String vetId) {
    final normalizedVetId = vetId.trim();
    if (normalizedVetId.isEmpty) return;
    final topic = 'vet-dashboard:$normalizedVetId';
    if (_dashboardBroadcastTopic == topic &&
        _dashboardBroadcastChannel != null) {
      return;
    }

    _removeDashboardBroadcast();
    final channel = Supabase.instance.client.channel(
      topic,
      opts: const RealtimeChannelConfig(private: true),
    );
    channel
        .onBroadcast(
          event: 'dashboard_changed',
          callback: (_) => _scheduleDashboardRefresh(),
        )
        .subscribe();
    _dashboardBroadcastTopic = topic;
    _dashboardBroadcastChannel = channel;
  }

  void _removeDashboardBroadcast() {
    final channel = _dashboardBroadcastChannel;
    _dashboardBroadcastChannel = null;
    _dashboardBroadcastTopic = null;
    if (channel != null) {
      Supabase.instance.client.removeChannel(channel);
    }
  }

  void _removeDashboardRealtime() {
    final channels = List<RealtimeChannel>.from(_dashboardRealtimeChannels);
    _dashboardRealtimeChannels.clear();
    for (final channel in channels) {
      Supabase.instance.client.removeChannel(channel);
    }
  }

  Future<Map<String, dynamic>> _getGatewayJson(String path) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      throw const _VetProfileException(
          'Tu sesión expiró. Vuelve a iniciar sesión.');
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request =
          await client.getUrl(Uri.parse('${Environment.apiBaseUrl}$path'));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      final rawBody = await utf8.decoder.bind(response).join();
      final decoded =
          rawBody.trim().isEmpty ? <String, dynamic>{} : jsonDecode(rawBody);
      final data = _asMap(decoded) ?? <String, dynamic>{};
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _VetProfileException(_errorMessage(data, response.statusCode));
      }
      return data;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _patchGatewayJson(
      String path, Map<String, dynamic> body) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      throw const _VetProfileException(
          'Tu sesión expiró. Vuelve a iniciar sesión.');
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request =
          await client.patchUrl(Uri.parse('${Environment.apiBaseUrl}$path'));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.add(utf8.encode(jsonEncode(body)));
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      final rawBody = await utf8.decoder.bind(response).join();
      final decoded =
          rawBody.trim().isEmpty ? <String, dynamic>{} : jsonDecode(rawBody);
      final data = _asMap(decoded) ?? <String, dynamic>{};
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _VetProfileException(_errorMessage(data, response.statusCode));
      }
      return data;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _postGatewayJson(
      String path, Map<String, dynamic> body) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      throw const _VetProfileException(
          'Tu sesión expiró. Vuelve a iniciar sesión.');
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request =
          await client.postUrl(Uri.parse('${Environment.apiBaseUrl}$path'));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.add(utf8.encode(jsonEncode(body)));
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      final rawBody = await utf8.decoder.bind(response).join();
      final decoded =
          rawBody.trim().isEmpty ? <String, dynamic>{} : jsonDecode(rawBody);
      final data = _asMap(decoded) ?? <String, dynamic>{};
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _VetProfileException(_errorMessage(data, response.statusCode));
      }
      return data;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _saveProfile(Map<String, dynamic> body) async {
    await _patchGatewayJson('/vets/me/profile', body);
  }

  void _showHome() {
    setState(() => _showProfile = false);
    _playDashboardFade();
  }

  void _showProfileScreen() {
    setState(() {
      _profileBundleFuture = _loadProfileBundle();
      _showProfile = true;
    });
  }

  void _openVideoCall(String sessionId) {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty) return;
    context.push('/video/${Uri.encodeComponent(normalizedSessionId)}');
  }

  void _openVideoHandoff(_VideoJoinTarget target) {
    final sessionId = target.sessionId.trim();
    if (sessionId.isEmpty) return;
    _vetDashboardRoadmapLog(
        'handoff.open sessionId=$sessionId name=${target.name}');
    final handoffFuture = _getGatewayJson(
      '/sessions/${Uri.encodeComponent(sessionId)}/handoff',
    ).then((json) {
      final bundle = _SessionHandoffBundle.fromJson(json);
      _vetDashboardRoadmapLog(
          'handoff.fetch.succeeded sessionId=$sessionId ready=${bundle.ready} hasHandoff=${bundle.handoff != null}');
      return bundle;
    }).catchError((error) {
      _vetDashboardRoadmapLog(
          'handoff.fetch.failed sessionId=$sessionId error=$error');
      throw error;
    });

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return _PreCallHandoffSheet(
          target: target,
          handoffFuture: handoffFuture,
          onJoin: () {
            _vetDashboardRoadmapLog('handoff.join_video sessionId=$sessionId');
            Navigator.of(sheetContext).pop();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _openVideoCall(sessionId);
            });
          },
        );
      },
    );
  }

  void _openChat(String sessionId) {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty) return;
    context.push('/chat/${Uri.encodeComponent(normalizedSessionId)}');
  }

  Future<void> _endActiveConsult(_ActiveConsult consult) async {
    final sessionId = consult.sessionId.trim();
    if (sessionId.isEmpty || _endingConsultIds.contains(sessionId)) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF141417),
          title: const Text(
            'Finalizar consulta',
            style: TextStyle(color: Colors.white, fontFamily: 'ABC Diatype'),
          ),
          content: Text(
            '¿Quieres cerrar la consulta de ${consult.name}?',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.72),
                fontFamily: 'ABC Diatype'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('finalizar'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;

    setState(() => _endingConsultIds.add(sessionId));
    try {
      await _postGatewayJson(
          '/vets/me/consults/${Uri.encodeComponent(sessionId)}/end',
          const <String, dynamic>{});
      if (!mounted) return;
      _refreshDashboardQueue();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('consulta finalizada.')),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo finalizar: $err')),
      );
    } finally {
      if (mounted) {
        setState(() => _endingConsultIds.remove(sessionId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = _showProfile
        ? Padding(
            padding: const EdgeInsets.only(top: 28),
            child: _ProfilePage(
              profileBundleFuture: _profileBundleFuture,
              onSave: _saveProfile,
              onReload: () => setState(() {
                _profileBundleFuture = _loadProfileBundle();
              }),
            ),
          )
        : _DashboardPage(
            availableNow: _availableNow,
            profileBundleFuture: _profileBundleFuture,
            onJoinVideo: _openVideoHandoff,
            onOpenChat: _openChat,
            onEndConsult: _endActiveConsult,
            endingConsultIds: _endingConsultIds,
          );

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
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            opacity: _dashboardVisible ? 1 : 0,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              offset: _dashboardVisible ? Offset.zero : const Offset(0, 0.018),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 24, 32, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_showProfile)
                      _ProfileTopBar(onBack: _showHome)
                    else
                      _VetTopBar(
                        availableNow: _availableNow,
                        onHomeTap: _showHome,
                        onProfileTap: _showProfileScreen,
                        onAvailabilityChanged: (value) =>
                            setState(() => _availableNow = value),
                      ),
                    Expanded(child: content),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileTopBar extends StatelessWidget {
  const _ProfileTopBar({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: Align(
        alignment: Alignment.centerLeft,
        child: IconButton(
          onPressed: onBack,
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }
}

class _VetTopBar extends StatelessWidget {
  const _VetTopBar({
    required this.availableNow,
    required this.onHomeTap,
    required this.onProfileTap,
    required this.onAvailabilityChanged,
  });

  final bool availableNow;
  final VoidCallback onHomeTap;
  final VoidCallback onProfileTap;
  final ValueChanged<bool> onAvailabilityChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: onProfileTap,
              child: SizedBox(
                width: 34,
                height: 34,
                child: SvgPicture.asset(
                  'assets/icons/user.svg',
                  fit: BoxFit.contain,
                  colorFilter:
                      const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                ),
              ),
            ),
          ),
          GestureDetector(
            onTap: onHomeTap,
            child: SvgPicture.asset(
              'assets/icons/homelogo.svg',
              width: 91,
              height: 18,
              fit: BoxFit.contain,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: _TinyAvailabilitySwitch(
              value: availableNow,
              onChanged: onAvailabilityChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _TinyAvailabilitySwitch extends StatelessWidget {
  const _TinyAvailabilitySwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 48,
        height: 42,
        child: Align(
          alignment: Alignment.centerRight,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            width: 38,
            height: 22,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: value
                  ? Colors.white.withValues(alpha: 0.28)
                  : Colors.white.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                  color: Colors.white.withValues(alpha: value ? 0.45 : 0.22)),
            ),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 16,
                height: 16,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashboardPage extends StatelessWidget {
  const _DashboardPage({
    required this.availableNow,
    required this.profileBundleFuture,
    required this.onJoinVideo,
    required this.onOpenChat,
    required this.onEndConsult,
    required this.endingConsultIds,
  });

  final bool availableNow;
  final Future<_VetProfileBundle> profileBundleFuture;
  final ValueChanged<_VideoJoinTarget> onJoinVideo;
  final ValueChanged<String> onOpenChat;
  final ValueChanged<_ActiveConsult> onEndConsult;
  final Set<String> endingConsultIds;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 96),
                    _DashboardGreeting(
                        profileBundleFuture: profileBundleFuture),
                    const SizedBox(height: 6),
                    const SizedBox(
                      width: 332,
                      child: Text(
                        'Esta es tu actividad:',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontFamily: 'ABC Diatype',
                          fontWeight: FontWeight.w400,
                          height: 1.10,
                        ),
                      ),
                    ),
                    const SizedBox(height: 30),
                    const _BoltMark(),
                    const SizedBox(height: 42),
                    _ActivitySections(
                      availableNow: availableNow,
                      profileBundleFuture: profileBundleFuture,
                      onJoinVideo: onJoinVideo,
                      onOpenChat: onOpenChat,
                      onEndConsult: onEndConsult,
                      endingConsultIds: endingConsultIds,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const _VetMessageComposer(),
      ],
    );
  }
}

class _DashboardGreeting extends StatelessWidget {
  const _DashboardGreeting({required this.profileBundleFuture});

  final Future<_VetProfileBundle> profileBundleFuture;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_VetProfileBundle>(
      future: profileBundleFuture,
      builder: (context, snapshot) {
        final firstName = _firstNameFrom(snapshot.data?.profile.fullName);
        return Text(
          firstName == null ? '¡Hola!' : '¡Hola, $firstName!',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontFamily: 'ABC Diatype',
            fontWeight: FontWeight.w400,
          ),
        );
      },
    );
  }
}

class _BoltMark extends StatelessWidget {
  const _BoltMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.bolt, color: Colors.black, size: 18),
    );
  }
}

class _ActivitySections extends StatelessWidget {
  const _ActivitySections({
    required this.availableNow,
    required this.profileBundleFuture,
    required this.onJoinVideo,
    required this.onOpenChat,
    required this.onEndConsult,
    required this.endingConsultIds,
  });

  final bool availableNow;
  final Future<_VetProfileBundle> profileBundleFuture;
  final ValueChanged<_VideoJoinTarget> onJoinVideo;
  final ValueChanged<String> onOpenChat;
  final ValueChanged<_ActiveConsult> onEndConsult;
  final Set<String> endingConsultIds;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_VetProfileBundle>(
      future: profileBundleFuture,
      builder: (context, snapshot) {
        final queue = snapshot.data?.queue;
        final activeConsults =
            queue?.activeConsults ?? const <_ActiveConsult>[];
        final upcomingAppointments =
            queue?.upcomingAppointments ?? const <_UpcomingAppointment>[];
        final isLoading = snapshot.connectionState == ConnectionState.waiting;
        if (isLoading && snapshot.data == null) {
          return const SizedBox.shrink();
        }

        final hasJoinableVideo =
            activeConsults.any((consult) => consult.canJoinVideo);
        if (!isLoading &&
            activeConsults.isEmpty &&
            upcomingAppointments.isEmpty) {
          return const SizedBox.shrink();
        }

        final children = <Widget>[];
        if (isLoading || activeConsults.isNotEmpty) {
          children.addAll([
            _ActiveConsultsTitle(
              label: availableNow ? 'consultas activas:' : 'fuera de guardia:',
              live: availableNow && hasJoinableVideo,
            ),
            const SizedBox(height: 24),
            if (isLoading)
              const _LoadingTag()
            else
              _ActiveConsultEventList(
                consults: activeConsults,
                onJoinVideo: onJoinVideo,
                onOpenChat: onOpenChat,
                onEndConsult: onEndConsult,
                endingConsultIds: endingConsultIds,
              ),
          ]);
        }

        if (isLoading || upcomingAppointments.isNotEmpty) {
          if (children.isNotEmpty) {
            children.add(const SizedBox(height: 46));
          }
          children.addAll([
            const Text(
              'próximas consultas:',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 28),
            if (isLoading)
              const _LoadingTag()
            else
              _UpcomingAppointmentsList(
                appointments: upcomingAppointments,
                onJoinVideo: onJoinVideo,
              ),
          ]);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        );
      },
    );
  }
}

class _ActiveConsultEventList extends StatelessWidget {
  const _ActiveConsultEventList({
    required this.consults,
    required this.onJoinVideo,
    required this.onOpenChat,
    required this.onEndConsult,
    required this.endingConsultIds,
  });

  final List<_ActiveConsult> consults;
  final ValueChanged<_VideoJoinTarget> onJoinVideo;
  final ValueChanged<String> onOpenChat;
  final ValueChanged<_ActiveConsult> onEndConsult;
  final Set<String> endingConsultIds;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: consults.map((consult) {
        final isEnding = endingConsultIds.contains(consult.sessionId);
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _ActiveConsultEventRow(
            consult: consult,
            isEnding: isEnding,
            onJoinVideo: consult.canJoinVideo
                ? () => onJoinVideo(consult.videoJoinTarget)
                : null,
            onOpenChat: consult.canOpenChat
                ? () => onOpenChat(consult.sessionId)
                : null,
            onEndConsult: isEnding ? null : () => onEndConsult(consult),
          ),
        );
      }).toList(),
    );
  }
}

class _ActiveConsultsTitle extends StatelessWidget {
  const _ActiveConsultsTitle({required this.label, required this.live});

  final String label;
  final bool live;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (live) ...[
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: const Color(0xFF29D391),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF29D391).withValues(alpha: 0.55),
                  blurRadius: 12,
                  spreadRadius: 3,
                ),
              ],
            ),
          ),
          const SizedBox(width: 9),
        ],
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontFamily: 'ABC Diatype',
            fontWeight: FontWeight.w400,
          ),
        ),
      ],
    );
  }
}

class _ActiveConsultEventRow extends StatelessWidget {
  const _ActiveConsultEventRow({
    required this.consult,
    required this.isEnding,
    this.onJoinVideo,
    this.onOpenChat,
    this.onEndConsult,
  });

  final _ActiveConsult consult;
  final bool isEnding;
  final VoidCallback? onJoinVideo;
  final VoidCallback? onOpenChat;
  final VoidCallback? onEndConsult;

  @override
  Widget build(BuildContext context) {
    final action = onJoinVideo != null
        ? _InlineJoinButton(label: consult.name, onTap: onJoinVideo!)
        : onOpenChat != null
            ? _InlineChatButton(label: consult.name, onTap: onOpenChat!)
            : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (action != null)
                      Flexible(child: action)
                    else
                      Flexible(
                        child: Text(
                          consult.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontFamily: 'ABC Diatype',
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        consult.waitingLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.58),
                          fontSize: 13,
                          fontFamily: 'ABC Diatype',
                          fontWeight: FontWeight.w400,
                          height: 1.05,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _ConsultOptionsButton(
                enabled: onEndConsult != null,
                isEnding: isEnding,
                onEndConsult: onEndConsult,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children:
                consult.tags.map((label) => _ConsultTag(label: label)).toList(),
          ),
        ],
      ),
    );
  }
}

class _ConsultTag extends StatelessWidget {
  const _ConsultTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontFamily: 'ABC Diatype',
            fontWeight: FontWeight.w500,
            height: 1.0,
          ),
        ),
      ),
    );
  }
}

class _InlineJoinButton extends StatelessWidget {
  const _InlineJoinButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_rounded, color: Colors.black, size: 16),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 12,
                  fontFamily: 'ABC Diatype',
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

class _InlineChatButton extends StatelessWidget {
  const _InlineChatButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.chat_bubble_outline_rounded,
                color: Colors.black, size: 15),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 12,
                  fontFamily: 'ABC Diatype',
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

class _ConsultOptionsButton extends StatelessWidget {
  const _ConsultOptionsButton(
      {required this.enabled,
      required this.isEnding,
      required this.onEndConsult});

  final bool enabled;
  final bool isEnding;
  final VoidCallback? onEndConsult;

  @override
  Widget build(BuildContext context) {
    if (isEnding) {
      return const SizedBox(
        width: 38,
        height: 38,
        child: Center(
          child: SizedBox(
            width: 15,
            height: 15,
            child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white)),
          ),
        ),
      );
    }
    return IconButton(
      onPressed: enabled ? () => _showActions(context) : null,
      icon: Icon(
        Icons.more_horiz_rounded,
        color: enabled ? Colors.white : Colors.white.withValues(alpha: 0.35),
        size: 22,
      ),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 38, height: 38),
    );
  }

  void _showActions(BuildContext context) {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) {
        return CupertinoActionSheet(
          actions: [
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () {
                Navigator.of(sheetContext).pop();
                onEndConsult?.call();
              },
              child: const Text('finalizar consulta'),
            ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.of(sheetContext).pop(),
            child: const Text('cancelar'),
          ),
        );
      },
    );
  }
}

class _UpcomingAppointmentsList extends StatelessWidget {
  const _UpcomingAppointmentsList(
      {required this.appointments, required this.onJoinVideo});

  final List<_UpcomingAppointment> appointments;
  final ValueChanged<_VideoJoinTarget> onJoinVideo;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'hoy:',
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontFamily: 'ABC Diatype',
            fontWeight: FontWeight.w400,
          ),
        ),
        const SizedBox(height: 10),
        ...appointments.take(3).map((appointment) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              child: _UpcomingConsultPill(
                name: appointment.name,
                time: appointment.formattedStart,
                onJoin: appointment.canJoinVideo
                    ? () => onJoinVideo(appointment.videoJoinTarget)
                    : null,
              ),
            ),
          );
        }),
      ],
    );
  }
}

class _UpcomingConsultPill extends StatelessWidget {
  const _UpcomingConsultPill(
      {required this.name, required this.time, this.onJoin});

  final String name;
  final String time;
  final VoidCallback? onJoin;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 51,
      padding: const EdgeInsets.only(left: 21, right: 18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(40),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videocam_outlined, color: Colors.white, size: 19),
          const SizedBox(width: 18),
          Text(
            name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w400,
              height: 1.85,
            ),
          ),
          const SizedBox(width: 28),
          Text(
            time,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w300,
            ),
          ),
          if (onJoin != null) ...[
            const SizedBox(width: 12),
            _RoundVideoIconButton(onTap: onJoin!),
          ],
        ],
      ),
    );
  }
}

class _RoundVideoIconButton extends StatelessWidget {
  const _RoundVideoIconButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 34,
        height: 34,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        child:
            const Icon(Icons.videocam_rounded, color: Colors.black, size: 18),
      ),
    );
  }
}

class _LoadingTag extends StatelessWidget {
  const _LoadingTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 92,
      height: 30,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(40),
      ),
    );
  }
}

class _PreCallHandoffSheet extends StatelessWidget {
  const _PreCallHandoffSheet({
    required this.target,
    required this.handoffFuture,
    required this.onJoin,
  });

  final _VideoJoinTarget target;
  final Future<_SessionHandoffBundle> handoffFuture;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.88,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Color(0xFF111113),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: FutureBuilder<_SessionHandoffBundle>(
            future: handoffFuture,
            builder: (context, snapshot) {
              final bundle = snapshot.data;
              final session = bundle?.session;
              final handoff = bundle?.handoff;
              final petName = session?.petName.trim().isNotEmpty == true
                  ? session!.petName
                  : target.name;
              final priority =
                  handoff?.urgency ?? session?.priority ?? target.priority;
              final specialty = session?.specialtyName ?? target.specialtyName;
              final isLoading =
                  snapshot.connectionState == ConnectionState.waiting;
              final hasError = snapshot.hasError;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              petName.trim().isEmpty ? 'Consulta' : petName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontFamily: 'ABC Diatype',
                                fontWeight: FontWeight.w400,
                                height: 1.04,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _HandoffBadge(
                                    label: _handoffPriorityLabel(priority)),
                                if (specialty != null &&
                                    specialty.trim().isNotEmpty)
                                  _HandoffBadge(label: specialty.trim()),
                                const _HandoffBadge(label: 'video'),
                              ],
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white, size: 22),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (isLoading)
                            const _HandoffLoadingState()
                          else if (hasError)
                            const _HandoffFallbackState()
                          else if (handoff == null)
                            const _HandoffMissingState()
                          else
                            _HandoffReadyState(handoff: handoff),
                          const SizedBox(height: 20),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _JoinVideoButton(onTap: onJoin),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _HandoffReadyState extends StatelessWidget {
  const _HandoffReadyState({required this.handoff});

  final _AiHandoff handoff;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _HandoffSection(
          title: 'Resumen AI',
          child: Text(
            handoff.summaryText,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.86),
              fontSize: 15,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w400,
              height: 1.28,
            ),
          ),
        ),
        if (handoff.redFlags.isNotEmpty)
          _HandoffSection(
            title: 'Red flags',
            child: _HandoffBulletList(items: handoff.redFlags),
          ),
        if (handoff.reportedSigns.isNotEmpty)
          _HandoffSection(
            title: 'Signos reportados',
            child: _HandoffBulletList(items: handoff.reportedSigns),
          ),
        if (handoff.questionsAnswered.isNotEmpty)
          _HandoffSection(
            title: 'Respuestas del propietario',
            child: Column(
              children: handoff.questionsAnswered
                  .map((answer) => _HandoffAnswerRow(answer: answer))
                  .toList(),
            ),
          ),
        if (handoff.questionsUnanswered.isNotEmpty)
          _HandoffSection(
            title: 'Por confirmar',
            child: _HandoffBulletList(items: handoff.questionsUnanswered),
          ),
        if (handoff.recommendedFirstChecks.isNotEmpty)
          _HandoffSection(
            title: 'Primeras revisiones sugeridas',
            child: _HandoffBulletList(items: handoff.recommendedFirstChecks),
          ),
      ],
    );
  }
}

class _HandoffSection extends StatelessWidget {
  const _HandoffSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.48),
              fontSize: 12,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 9),
          child,
        ],
      ),
    );
  }
}

class _HandoffBulletList extends StatelessWidget {
  const _HandoffBulletList({required this.items});

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: items
          .map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.only(top: 7),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.62),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.78),
                        fontSize: 14,
                        fontFamily: 'ABC Diatype',
                        fontWeight: FontWeight.w400,
                        height: 1.28,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }
}

class _HandoffAnswerRow extends StatelessWidget {
  const _HandoffAnswerRow({required this.answer});

  final _HandoffQuestionAnswer answer;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            answer.question,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.52),
              fontSize: 12,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w400,
              height: 1.24,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            answer.answer,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.86),
              fontSize: 14,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w400,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}

class _HandoffLoadingState extends StatelessWidget {
  const _HandoffLoadingState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child:
                CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Text(
            'Cargando handoff AI...',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.66),
              fontSize: 14,
              fontFamily: 'ABC Diatype',
            ),
          ),
        ],
      ),
    );
  }
}

class _HandoffFallbackState extends StatelessWidget {
  const _HandoffFallbackState();

  @override
  Widget build(BuildContext context) {
    return const _HandoffNotice(
      icon: Icons.cloud_off_rounded,
      title: 'Handoff no disponible',
      message:
          'Puedes entrar a la videollamada mientras se recupera el contexto.',
    );
  }
}

class _HandoffMissingState extends StatelessWidget {
  const _HandoffMissingState();

  @override
  Widget build(BuildContext context) {
    return const _HandoffNotice(
      icon: Icons.notes_rounded,
      title: 'Sin handoff AI todavía',
      message:
          'La sesión no tiene un handoff generado, pero puedes entrar a la videollamada.',
    );
  }
}

class _HandoffNotice extends StatelessWidget {
  const _HandoffNotice({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.white.withValues(alpha: 0.76), size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontFamily: 'ABC Diatype',
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  message,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.68),
                    fontSize: 13,
                    fontFamily: 'ABC Diatype',
                    fontWeight: FontWeight.w400,
                    height: 1.28,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HandoffBadge extends StatelessWidget {
  const _HandoffBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontFamily: 'ABC Diatype',
            fontWeight: FontWeight.w500,
            height: 1.0,
          ),
        ),
      ),
    );
  }
}

class _JoinVideoButton extends StatelessWidget {
  const _JoinVideoButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        height: 52,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.videocam_rounded, color: Colors.black, size: 18),
            SizedBox(width: 9),
            Text(
              'Entrar a videollamada',
              style: TextStyle(
                color: Colors.black,
                fontSize: 14,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VetMessageComposer extends StatelessWidget {
  const _VetMessageComposer();

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: 1.10,
      child: Container(
        height: 40,
        padding: const EdgeInsets.only(left: 20, right: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(40),
        ),
        child: Row(
          children: [
            Text(
              'escribir mensaje...',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.30),
                fontSize: 13,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            SvgPicture.asset(
              'assets/icons/rightup.svg',
              width: 17,
              height: 17,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfilePage extends StatelessWidget {
  const _ProfilePage({
    required this.profileBundleFuture,
    required this.onSave,
    required this.onReload,
  });

  final Future<_VetProfileBundle> profileBundleFuture;
  final Future<void> Function(Map<String, dynamic> body) onSave;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_VetProfileBundle>(
      future: profileBundleFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
              child: CircularProgressIndicator(color: Colors.white));
        }
        if (snapshot.hasError) {
          return _ProfileError(
              message: snapshot.error.toString(), onReload: onReload);
        }
        final bundle = snapshot.data;
        if (bundle == null) {
          return _ProfileError(
              message: 'No pude cargar el perfil veterinario.',
              onReload: onReload);
        }
        return _ProfileEditor(bundle: bundle, onSave: onSave);
      },
    );
  }
}

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor({required this.bundle, required this.onSave});

  final _VetProfileBundle bundle;
  final Future<void> Function(Map<String, dynamic> body) onSave;

  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  late final TextEditingController _bioController;
  late Set<String> _selectedSpecialtyIds;
  bool _saving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    final profile = widget.bundle.profile;
    _bioController = TextEditingController(text: profile.bio);
    _selectedSpecialtyIds = profile.specialtyIds.toSet();
  }

  @override
  void dispose() {
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _message = null;
    });

    try {
      await widget.onSave({
        'bio': _bioController.text.trim(),
        'specialties': _selectedSpecialtyIds.toList(),
      });
      if (!mounted) return;
      setState(() => _message = 'Perfil actualizado.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = 'No pude guardar: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editField(
    TextEditingController controller,
    String label, {
    int maxLines = 1,
    TextInputType? keyboardType,
  }) async {
    final draftController = TextEditingController(text: controller.text);
    final nextValue = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101010),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        final bottomInset = MediaQuery.of(context).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(24, 22, 24, 24 + bottomInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontFamily: 'ABC Diatype',
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: draftController,
                autofocus: true,
                maxLines: maxLines,
                keyboardType: keyboardType,
                cursorColor: Colors.white,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontFamily: 'ABC Diatype',
                  fontWeight: FontWeight.w400,
                ),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: 'tocar para añadir',
                  hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.28),
                    fontSize: 18,
                    fontFamily: 'ABC Diatype',
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: _OnboardingStyleAction(
                  label: 'listo',
                  onPressed: () =>
                      Navigator.of(context).pop(draftController.text),
                ),
              ),
            ],
          ),
        );
      },
    );
    draftController.dispose();
    if (nextValue == null) return;
    setState(() => controller.text = nextValue.trim());
  }

  void _toggleSpecialty(String id) {
    setState(() {
      if (_selectedSpecialtyIds.contains(id)) {
        _selectedSpecialtyIds.remove(id);
      } else {
        _selectedSpecialtyIds.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.bundle.profile;
    final metadata = [
      profile.email,
      profile.phone,
      profile.licenseNumber,
      if (profile.ratingCount > 0)
        '${profile.ratingAverage.toStringAsFixed(1)} (${profile.ratingCount})',
    ].where((value) => value.trim().isNotEmpty).toList();
    return Column(
      children: [
        Expanded(
          child: ListView(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Perfil veterinario',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontFamily: 'ABC Diatype',
                            fontWeight: FontWeight.w400,
                            height: 1.02,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          profile.fullName.isEmpty
                              ? 'Veterinario Call a Vet'
                              : profile.fullName,
                          style: TextStyle(
                            color: Colors.white.withAlpha(180),
                            fontSize: 13,
                            fontFamily: 'ABC Diatype',
                          ),
                        ),
                      ],
                    ),
                  ),
                  _ApprovalBadge(isApproved: profile.isApproved),
                ],
              ),
              const SizedBox(height: 18),
              ...metadata.map((value) => _ProfileMetaText(value)),
              const SizedBox(height: 20),
              _EditableProfileLine(
                label: 'Bio profesional',
                value: _bioController.text,
                maxLines: 4,
                onTap: () =>
                    _editField(_bioController, 'Bio profesional', maxLines: 5),
              ),
              const SizedBox(height: 10),
              const Text(
                'Especialidades',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontFamily: 'ABC Diatype',
                    fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 10,
                children: widget.bundle.specialties.map((specialty) {
                  final selected = _selectedSpecialtyIds.contains(specialty.id);
                  return _SpecialtyToggleTag(
                    label: specialty.name,
                    selected: selected,
                    onTap: () => _toggleSpecialty(specialty.id),
                  );
                }).toList(),
              ),
              if (_message != null) ...[
                const SizedBox(height: 12),
                Text(
                  _message!,
                  style: TextStyle(
                    color: _message!.startsWith('No pude')
                        ? const Color(0xFFFF8A80)
                        : Colors.white.withAlpha(190),
                    fontSize: 12,
                    fontFamily: 'ABCDiatype',
                  ),
                ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: _OnboardingStyleAction(
            label: 'guardar cambios',
            busy: _saving,
            onPressed: _saving ? null : _save,
          ),
        ),
      ],
    );
  }
}

class _EditableProfileLine extends StatelessWidget {
  const _EditableProfileLine({
    required this.label,
    required this.value,
    required this.onTap,
    this.maxLines = 1,
  });

  final String label;
  final String value;
  final VoidCallback onTap;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final trimmed = value.trim();
    final hasValue = trimmed.isNotEmpty;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.46),
                fontSize: 11,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              hasValue ? trimmed : 'tocar para añadir',
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: hasValue ? 1 : 0.30),
                fontSize: 16,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w400,
                height: 1.25,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileMetaText extends StatelessWidget {
  const _ProfileMetaText(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        value,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.64),
          fontSize: 12,
          fontFamily: 'ABC Diatype',
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }
}

class _SpecialtyToggleTag extends StatelessWidget {
  const _SpecialtyToggleTag(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? Colors.black : Colors.white,
          borderRadius: BorderRadius.circular(999),
        ),
        child: SizedBox(
          height: 38,
          child: Padding(
            padding: const EdgeInsets.only(left: 18, right: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  softWrap: false,
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.black,
                    fontSize: 15,
                    fontFamily: 'ABC Diatype',
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 19,
                  height: 19,
                  child: Icon(
                    selected ? Icons.close_rounded : Icons.add_rounded,
                    color: selected ? Colors.white : Colors.black,
                    size: 18,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OnboardingStyleAction extends StatelessWidget {
  const _OnboardingStyleAction(
      {required this.label, required this.onPressed, this.busy = false});

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return GestureDetector(
      onTap: enabled ? onPressed : null,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: enabled || busy ? 1 : 0.35,
        child: SizedBox(
          height: 45,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                label,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontFamily: 'ABC Diatype',
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 8),
              busy
                  ? const SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        ),
                      ),
                    )
                  : SvgPicture.asset(
                      'assets/icons/continue.svg',
                      width: 48,
                      height: 48,
                      colorFilter:
                          const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ApprovalBadge extends StatelessWidget {
  const _ApprovalBadge({required this.isApproved});

  final bool isApproved;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isApproved ? const Color(0x3329D391) : const Color(0x33FFB4AB),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
            color:
                isApproved ? const Color(0xAA29D391) : const Color(0xAAFFB4AB)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          isApproved ? 'aprobado' : 'pendiente',
          style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontFamily: 'ABCDiatype',
              fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}

class _ProfileError extends StatelessWidget {
  const _ProfileError({required this.message, required this.onReload});

  final String message;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.badge_outlined, size: 42, color: Colors.white),
            const SizedBox(height: 14),
            const Text('Perfil veterinario',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontFamily: 'ABCDiatype')),
            const SizedBox(height: 8),
            Text(message,
                style: TextStyle(
                    color: Colors.white.withAlpha(175),
                    fontSize: 13,
                    fontFamily: 'ABCDiatype'),
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            TextButton(
                onPressed: onReload,
                child: const Text('reintentar',
                    style: TextStyle(color: Colors.white))),
          ],
        ),
      ),
    );
  }
}

class _VetProfileBundle {
  const _VetProfileBundle(
      {required this.profile, required this.specialties, required this.queue});

  final _VetProfile profile;
  final List<_VetSpecialty> specialties;
  final _VetQueue queue;

  _VetProfileBundle copyWith({_VetQueue? queue}) {
    return _VetProfileBundle(
      profile: profile,
      specialties: specialties,
      queue: queue ?? this.queue,
    );
  }
}

class _VetQueue {
  const _VetQueue(
      {required this.activeConsults, required this.upcomingAppointments});

  factory _VetQueue.fromJson(Map<String, dynamic> json) {
    return _VetQueue(
      activeConsults: _asList(json['activeConsults'])
              ?.map(_asMap)
              .whereType<Map<String, dynamic>>()
              .map(_ActiveConsult.fromJson)
              .toList() ??
          const <_ActiveConsult>[],
      upcomingAppointments: _asList(json['upcomingAppointments'])
              ?.map(_asMap)
              .whereType<Map<String, dynamic>>()
              .map(_UpcomingAppointment.fromJson)
              .toList() ??
          const <_UpcomingAppointment>[],
    );
  }

  final List<_ActiveConsult> activeConsults;
  final List<_UpcomingAppointment> upcomingAppointments;
}

class _ActiveConsult {
  const _ActiveConsult({
    required this.sessionId,
    required this.name,
    required this.status,
    required this.mode,
    required this.startedAt,
    required this.lifecycleStatus,
    required this.specialtyName,
    required this.priority,
  });

  factory _ActiveConsult.fromJson(Map<String, dynamic> json) {
    final mode = _normalizeConsultMode(json['mode']);
    return _ActiveConsult(
      sessionId: json['session_id']?.toString() ?? '',
      name: _displayName(json),
      status: json['status']?.toString() ?? 'activa',
      mode: mode,
      startedAt: _parseDateTime(json['started_at']),
      lifecycleStatus: json['lifecycle_status']?.toString(),
      specialtyName: json['specialty_name']?.toString(),
      priority: json['priority']?.toString(),
    );
  }

  final String sessionId;
  final String name;
  final String status;
  final String mode;
  final DateTime? startedAt;
  final String? lifecycleStatus;
  final String? specialtyName;
  final String? priority;

  bool get canJoinVideo => mode == 'video' && sessionId.trim().isNotEmpty;
  bool get canOpenChat => mode == 'chat' && sessionId.trim().isNotEmpty;
  String get startedLabel => startedAt == null
      ? 'inicio por confirmar'
      : 'inició ${_formatShortDateTime(startedAt!)}';
  String get waitingLabel {
    final started = startedAt;
    if (started == null) return 'hace un momento...';
    return 'hace ${_formatElapsedSince(started)}...';
  }

  List<String> get tags {
    final values = <String>[];
    final lifecycle = lifecycleStatus?.trim().toLowerCase();
    if (lifecycle != null &&
        lifecycle.isNotEmpty &&
        lifecycle != 'pending' &&
        lifecycle != 'waiting' &&
        lifecycle != 'live' &&
        lifecycle != status.toLowerCase() &&
        lifecycle != mode.toLowerCase()) {
      values.add(lifecycle.replaceAll('_', ' '));
    }
    final priorityLabel = _consultPriorityLabel(priority);
    if (priorityLabel != null) values.add(priorityLabel);
    final specialty = specialtyName?.trim();
    if (specialty != null && specialty.isNotEmpty) values.add(specialty);
    return values;
  }

  _VideoJoinTarget get videoJoinTarget => _VideoJoinTarget(
        sessionId: sessionId,
        name: name,
        priority: priority,
        specialtyName: specialtyName,
      );
}

class _UpcomingAppointment {
  const _UpcomingAppointment(
      {required this.sessionId,
      required this.name,
      required this.startsAt,
      required this.mode});

  factory _UpcomingAppointment.fromJson(Map<String, dynamic> json) {
    return _UpcomingAppointment(
      sessionId: json['session_id']?.toString() ?? '',
      name: _displayName(json),
      startsAt: _parseDateTime(json['starts_at']),
      mode: _normalizeConsultMode(json['mode'], fallback: 'video'),
    );
  }

  final String sessionId;
  final String name;
  final DateTime? startsAt;
  final String mode;

  String get formattedStart => startsAt == null
      ? 'hora por confirmar'
      : _formatAppointmentDate(startsAt!);
  bool get canJoinVideo => mode == 'video' && sessionId.trim().isNotEmpty;
  _VideoJoinTarget get videoJoinTarget => _VideoJoinTarget(
        sessionId: sessionId,
        name: name,
      );
}

class _VideoJoinTarget {
  const _VideoJoinTarget({
    required this.sessionId,
    required this.name,
    this.priority,
    this.specialtyName,
  });

  final String sessionId;
  final String name;
  final String? priority;
  final String? specialtyName;
}

class _SessionHandoffBundle {
  const _SessionHandoffBundle(
      {required this.ready, this.session, this.handoff});

  factory _SessionHandoffBundle.fromJson(Map<String, dynamic> json) {
    final sessionMap = _asMap(json['session']);
    final handoffMap = _asMap(json['handoff']);
    return _SessionHandoffBundle(
      ready: json['ready'] == true,
      session: sessionMap == null ? null : _HandoffSession.fromJson(sessionMap),
      handoff: handoffMap == null ? null : _AiHandoff.fromJson(handoffMap),
    );
  }

  final bool ready;
  final _HandoffSession? session;
  final _AiHandoff? handoff;
}

class _HandoffSession {
  const _HandoffSession({
    required this.id,
    required this.petName,
    this.priority,
    this.specialtyName,
  });

  factory _HandoffSession.fromJson(Map<String, dynamic> json) {
    return _HandoffSession(
      id: json['id']?.toString() ?? '',
      petName: json['petName']?.toString() ?? '',
      priority: json['priority']?.toString(),
      specialtyName: json['specialtyName']?.toString(),
    );
  }

  final String id;
  final String petName;
  final String? priority;
  final String? specialtyName;
}

class _AiHandoff {
  const _AiHandoff({
    required this.urgency,
    required this.summaryText,
    required this.reportedSigns,
    required this.redFlags,
    required this.questionsAnswered,
    required this.questionsUnanswered,
    required this.recommendedFirstChecks,
  });

  factory _AiHandoff.fromJson(Map<String, dynamic> json) {
    return _AiHandoff(
      urgency: json['urgency']?.toString() ?? 'routine',
      summaryText: json['summaryText']?.toString() ?? '',
      reportedSigns: _stringList(json['reportedSigns']),
      redFlags: _stringList(json['redFlags']),
      questionsAnswered: _asList(json['questionsAnswered'])
              ?.map(_asMap)
              .whereType<Map<String, dynamic>>()
              .map(_HandoffQuestionAnswer.fromJson)
              .where((answer) =>
                  answer.question.isNotEmpty && answer.answer.isNotEmpty)
              .toList() ??
          const <_HandoffQuestionAnswer>[],
      questionsUnanswered: _stringList(json['questionsUnanswered']),
      recommendedFirstChecks: _stringList(json['recommendedFirstChecks']),
    );
  }

  final String urgency;
  final String summaryText;
  final List<String> reportedSigns;
  final List<String> redFlags;
  final List<_HandoffQuestionAnswer> questionsAnswered;
  final List<String> questionsUnanswered;
  final List<String> recommendedFirstChecks;
}

class _HandoffQuestionAnswer {
  const _HandoffQuestionAnswer({required this.question, required this.answer});

  factory _HandoffQuestionAnswer.fromJson(Map<String, dynamic> json) {
    return _HandoffQuestionAnswer(
      question: json['question']?.toString().trim() ?? '',
      answer: json['answer']?.toString().trim() ?? '',
    );
  }

  final String question;
  final String answer;
}

class _VetProfile {
  const _VetProfile({
    required this.id,
    required this.fullName,
    required this.email,
    required this.phone,
    required this.licenseNumber,
    required this.country,
    required this.bio,
    required this.yearsExperience,
    required this.isApproved,
    required this.languages,
    required this.specialtyIds,
    required this.ratingAverage,
    required this.ratingCount,
  });

  factory _VetProfile.fromJson(Map<String, dynamic> json) {
    return _VetProfile(
      id: json['id']?.toString() ?? '',
      fullName: json['full_name']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      phone: json['phone']?.toString() ?? '',
      licenseNumber: json['license_number']?.toString() ?? '',
      country: json['country']?.toString() ?? '',
      bio: json['bio']?.toString() ?? '',
      yearsExperience: _toInt(json['years_experience']),
      isApproved: json['is_approved'] == true,
      languages: _asList(json['languages'])
              ?.map((value) => value.toString())
              .toList() ??
          const <String>[],
      specialtyIds: _asList(json['specialties'])
              ?.map((value) => value.toString())
              .toList() ??
          const <String>[],
      ratingAverage: _toDouble(json['rating_average']) ?? 0,
      ratingCount: _toInt(json['rating_count']) ?? 0,
    );
  }

  final String id;
  final String fullName;
  final String email;
  final String phone;
  final String licenseNumber;
  final String country;
  final String bio;
  final int? yearsExperience;
  final bool isApproved;
  final List<String> languages;
  final List<String> specialtyIds;
  final double ratingAverage;
  final int ratingCount;
}

class _VetSpecialty {
  const _VetSpecialty(
      {required this.id, required this.name, required this.isActive});

  factory _VetSpecialty.fromJson(Map<String, dynamic> json) {
    return _VetSpecialty(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      isActive: json['is_active'] != false,
    );
  }

  final String id;
  final String name;
  final bool isActive;
}

class _VetProfileException implements Exception {
  const _VetProfileException(this.message);

  final String message;

  @override
  String toString() => message;
}

Map<String, dynamic>? _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, entry) => MapEntry(key.toString(), entry));
  }
  return null;
}

List<dynamic>? _asList(Object? value) => value is List ? value : null;

List<String> _stringList(Object? value) {
  return _asList(value)
          ?.map((item) => item?.toString().trim() ?? '')
          .where((item) => item.isNotEmpty)
          .toList() ??
      const <String>[];
}

int? _toInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

double? _toDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

String? _firstNameFrom(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed.split(RegExp(r'\s+')).first;
}

String _displayName(Map<String, dynamic> json) {
  final petName = json['pet_name']?.toString().trim();
  if (petName != null && petName.isNotEmpty) return petName;
  final userName = json['user_name']?.toString().trim();
  if (userName != null && userName.isNotEmpty) return userName;
  return 'consulta';
}

String _normalizeConsultMode(Object? value, {String fallback = 'chat'}) {
  final normalized = value?.toString().trim().toLowerCase();
  if (normalized == 'video' || normalized == 'scheduled_video') return 'video';
  if (normalized == 'chat') return 'chat';
  return fallback;
}

String _handoffPriorityLabel(String? value) {
  final normalized = value?.trim().toLowerCase();
  if (normalized == 'emergency') return 'emergencia';
  if (normalized == 'urgent') return 'urgente';
  return 'rutina';
}

DateTime? _parseDateTime(Object? value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString())?.toLocal();
}

String _formatAppointmentDate(DateTime value) {
  final day = value.day.toString().padLeft(2, '0');
  final month = value.month.toString().padLeft(2, '0');
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$day/$month/${value.year}  $hour:${minute}hrs';
}

String _formatShortDateTime(DateTime value) {
  final day = value.day.toString().padLeft(2, '0');
  final month = value.month.toString().padLeft(2, '0');
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$day/$month $hour:$minute';
}

String _formatElapsedSince(DateTime value) {
  final elapsed = DateTime.now().difference(value);
  if (elapsed.inMinutes < 1) return 'menos de 1 minuto';
  if (elapsed.inMinutes == 1) return '1 minuto';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes} minutos';
  final hours = elapsed.inHours;
  final minutes = elapsed.inMinutes.remainder(60);
  final hourText = hours == 1 ? '1 hora' : '$hours horas';
  if (minutes == 0) return hourText;
  final minuteText = minutes == 1 ? '1 minuto' : '$minutes minutos';
  return '$hourText $minuteText';
}

String? _consultPriorityLabel(String? value) {
  final normalized = value?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty || normalized == 'routine') {
    return null;
  }
  if (normalized == 'urgent') return 'urgente';
  if (normalized == 'emergency') return 'emergencia';
  return normalized.replaceAll('_', ' ');
}

String _errorMessage(Map<String, dynamic> data, int statusCode) {
  final message = data['message']?.toString();
  if (message != null && message.isNotEmpty) return message;
  final reason = data['reason']?.toString();
  if (reason != null && reason.isNotEmpty) return reason;
  return 'Error del servidor ($statusCode).';
}
