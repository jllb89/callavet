import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/environment.dart';

void _ownerVideoLog(String message) {
  debugPrint('[VideoRoadmap][Owner] $message');
}

class VideoCallScreen extends StatefulWidget {
  const VideoCallScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen> {
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  String? _roomName;
  String? _error;
  bool _connecting = true;
  bool _ending = false;
  bool _micEnabled = true;
  bool _cameraEnabled = true;
  bool _returningToChat = false;
  CameraPosition _cameraPosition = CameraPosition.front;
  _VideoEndState? _endState;
  String? _postCallAssistantMessage;

  @override
  void initState() {
    super.initState();
    _ownerVideoLog('init sessionId=${widget.sessionId}');
    unawaited(_connect());
  }

  @override
  void dispose() {
    final room = _room;
    room?.removeListener(_handleRoomUpdate);
    final listenerDispose = _listener?.dispose();
    if (listenerDispose != null) unawaited(listenerDispose);
    final disconnect = room?.disconnect();
    if (disconnect != null) unawaited(disconnect);
    final roomDispose = room?.dispose();
    if (roomDispose != null) unawaited(roomDispose);
    super.dispose();
  }

  Future<void> _connect() async {
    try {
      _ownerVideoLog('connect.start sessionId=${widget.sessionId}');
      final credentials = await _createVideoRoom(widget.sessionId);
      final url = credentials['url']?.toString() ?? '';
      final token = credentials['token']?.toString() ?? '';
      final roomName = credentials['roomName']?.toString() ??
          credentials['roomId']?.toString() ??
          '';
      if (url.isEmpty || token.isEmpty || roomName.isEmpty) {
        throw const _VideoCallException(
            'No pude obtener credenciales de video.');
      }
      _ownerVideoLog('connect.credentials sessionId=${widget.sessionId} roomName=$roomName');

      final room = Room(
        roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true),
      );
      final listener = room.createListener()
        ..on<ParticipantEvent>((_) => _handleRoomUpdate())
        ..on<LocalTrackPublishedEvent>((_) => _handleRoomUpdate())
        ..on<LocalTrackUnpublishedEvent>((_) => _handleRoomUpdate())
        ..on<TrackSubscribedEvent>((_) => _handleRoomUpdate())
        ..on<TrackUnsubscribedEvent>((_) => _handleRoomUpdate())
        ..on<RoomDisconnectedEvent>((_) => unawaited(_handleRoomDisconnected()));
      room.addListener(_handleRoomUpdate);

      if (!mounted) {
        await listener.dispose();
        await room.dispose();
        return;
      }

      setState(() {
        _room = room;
        _listener = listener;
        _roomName = roomName;
      });

      await room.connect(url, token);
      final mediaWarning = await _publishInitialTracks(room);
      if (!mounted) return;
      _ownerVideoLog('connect.succeeded sessionId=${widget.sessionId} roomName=$roomName mediaWarning=${mediaWarning != null}');
      setState(() {
        _connecting = false;
        _error = mediaWarning;
        _micEnabled = _hasActiveAudio(room.localParticipant);
        _cameraEnabled = _hasActiveVideo(room.localParticipant);
      });
    } catch (error) {
      if (!mounted) return;
      _ownerVideoLog('connect.failed sessionId=${widget.sessionId} error=$error');
      setState(() {
        _connecting = false;
        _error = error.toString();
      });
    }
  }

  Future<String?> _publishInitialTracks(Room room) async {
    if (await _isIosSimulator()) {
      return 'El simulador iOS no puede publicar camara o microfono de forma estable. La sala queda conectada para pruebas; usa dispositivos reales para audio/video.';
    }
    final warnings = <String>[];
    try {
      await room.localParticipant?.setMicrophoneEnabled(true);
    } catch (error) {
      debugPrint('[VideoCall] Microphone publish failed: $error');
      warnings.add('No pude activar el microfono. Revisa permisos de audio.');
    }
    try {
      await room.localParticipant?.setCameraEnabled(true);
    } catch (error) {
      debugPrint('[VideoCall] Camera publish failed: $error');
      warnings.add('No pude activar la camara. Puedes continuar con audio o intentar activarla de nuevo.');
    }
    return warnings.isEmpty ? null : warnings.join(' ');
  }

  void _handleRoomUpdate() {
    if (!mounted) return;
    final localParticipant = _room?.localParticipant;
    setState(() {
      if (localParticipant != null) {
        _micEnabled = _hasActiveAudio(localParticipant);
        _cameraEnabled = _hasActiveVideo(localParticipant);
      }
    });
  }

  Future<void> _handleRoomDisconnected() async {
    _handleRoomUpdate();
    if (!mounted || _ending) return;
    _ownerVideoLog('disconnect.remote sessionId=${widget.sessionId} roomName=$_roomName');
    setState(() {
      _connecting = false;
      _room = null;
      _returningToChat = true;
      _error = null;
    });
    final endState = await _fetchEndState().catchError((_) => null);
    final postCallMessage = endState == null
        ? null
        : await _generatePostCallMessage(endState).catchError((_) => null);
    if (!mounted || _ending) return;
    _ownerVideoLog(
      'disconnect.resolved sessionId=${widget.sessionId} endReason=${endState?.endReason} endedBy=${endState?.endedByRole} rejoin=${endState?.rejoinEligible} postCallMessage=${postCallMessage?.trim().isNotEmpty == true}');
    if (endState != null && endState.shouldReturnToChat) {
      _ownerVideoLog('disconnect.open_chat sessionId=${widget.sessionId} endReason=${endState.endReason}');
      _openPostCallChat(postCallMessage, rejoinEligible: endState.rejoinEligible);
      return;
    }
    setState(() {
      _connecting = false;
      _room = null;
      _returningToChat = false;
      _endState = endState;
      _postCallAssistantMessage = postCallMessage;
      _error = endState?.message ??
          'La videollamada se desconecto. Puedes volver e intentarlo otra vez.';
    });
  }

  Future<void> _toggleMicrophone() async {
    if (await _isIosSimulator()) {
      setState(() => _error = 'El microfono no esta disponible en el simulador iOS. Prueba audio en un dispositivo real.');
      return;
    }
    final participant = _room?.localParticipant;
    if (participant == null) return;
    final nextValue = !_micEnabled;
    setState(() => _micEnabled = nextValue);
    try {
      await participant.setMicrophoneEnabled(nextValue);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _micEnabled = !nextValue;
        _error = 'No pude cambiar el microfono: $error';
      });
    }
  }

  Future<void> _toggleCamera() async {
    if (await _isIosSimulator()) {
      setState(() => _error = 'La camara no esta disponible en el simulador iOS. Prueba video en un dispositivo real.');
      return;
    }
    final participant = _room?.localParticipant;
    if (participant == null) return;
    final nextValue = !_cameraEnabled;
    setState(() => _cameraEnabled = nextValue);
    try {
      await participant.setCameraEnabled(nextValue);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cameraEnabled = !nextValue;
        _error = 'No pude cambiar la camara: $error';
      });
    }
  }

  Future<void> _switchCamera() async {
    if (await _isIosSimulator()) {
      setState(() => _error = 'El cambio de camara no esta disponible en el simulador iOS.');
      return;
    }
    final participant = _room?.localParticipant;
    if (participant == null) return;
    final track = _localCameraTrack(participant);
    if (track == null) {
      try {
        await participant.setCameraEnabled(true);
      } catch (error) {
        if (!mounted) return;
        setState(() => _error = 'No pude activar la camara: $error');
      }
      return;
    }
    final nextPosition = _cameraPosition == CameraPosition.front
        ? CameraPosition.back
        : CameraPosition.front;
    try {
      await track.setCameraPosition(nextPosition);
      if (!mounted) return;
      setState(() => _cameraPosition = nextPosition);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'No pude cambiar de camara: $error');
    }
  }

  Future<void> _leaveCall() async {
    if (_ending) return;
    _ownerVideoLog('leave.requested sessionId=${widget.sessionId} roomName=$_roomName');
    setState(() {
      _ending = true;
      _returningToChat = true;
    });
    _VideoEndState? endState;
    String? postCallMessage;
    try {
      final roomName = _roomName;
      if (roomName != null && roomName.isNotEmpty) {
        final response = await _endRoom(roomName);
        final stateData = _asMap(response['endState']);
        if (stateData != null) endState = _VideoEndState.fromJson(stateData);
        _ownerVideoLog('leave.end_room_response sessionId=${widget.sessionId} endReason=${endState?.endReason} rejoin=${endState?.rejoinEligible}');
      }
    } catch (error) {
      _ownerVideoLog('leave.end_room_failed sessionId=${widget.sessionId} error=$error');
      debugPrint('[VideoCall] Room end failed: $error');
    }
    if (endState != null) {
      postCallMessage = await _generatePostCallMessage(endState).catchError((_) => null);
      _ownerVideoLog('leave.post_call_message sessionId=${widget.sessionId} generated=${postCallMessage?.trim().isNotEmpty == true}');
    }
    try {
      await _room?.disconnect();
    } catch (error) {
      debugPrint('[VideoCall] Disconnect failed: $error');
    }
    if (!mounted) return;
    _ownerVideoLog('leave.open_chat sessionId=${widget.sessionId} hasAssistantMessage=${postCallMessage?.trim().isNotEmpty == true}');
    _openPostCallChat(postCallMessage, rejoinEligible: endState?.rejoinEligible == true);
  }

  void _rejoinCall() {
    if (_connecting) return;
    _ownerVideoLog('rejoin.requested sessionId=${widget.sessionId}');
    setState(() {
      _room = null;
      _error = null;
      _endState = null;
      _postCallAssistantMessage = null;
      _returningToChat = false;
      _connecting = true;
      _ending = false;
    });
    unawaited(_connect());
  }

  void _openPostCallChat(String? assistantMessage, {bool rejoinEligible = false}) {
    final message = assistantMessage?.trim();
    _ownerVideoLog('post_call.open_chat sessionId=${widget.sessionId} hasAssistantMessage=${message?.isNotEmpty == true} rejoinEligible=$rejoinEligible');
    final params = <String, String>{
      if (message != null && message.isNotEmpty) 'assistantMessage': message,
      if (rejoinEligible) 'rejoinVideo': 'true',
    };
    final query = params.isEmpty ? '' : '?${Uri(queryParameters: params).query}';
    context.go('/chat/${Uri.encodeComponent(widget.sessionId)}$query');
  }

  Future<Map<String, dynamic>> _createVideoRoom(String sessionId) {
    _ownerVideoLog('room.create.request sessionId=$sessionId');
    return _postGatewayJson(
        '/video/rooms', {'sessionId': sessionId, 'participantRole': 'owner'});
  }

  Future<Map<String, dynamic>> _endRoom(String roomName) async {
    return _postGatewayJson('/video/rooms/${Uri.encodeComponent(roomName)}/end', {
      'participantRole': 'owner',
      'reason': 'owner_ended',
    });
  }

  Future<_VideoEndState?> _fetchEndState() async {
    _ownerVideoLog('end_state.fetch sessionId=${widget.sessionId}');
    final data = await _getGatewayJson(
      '/video/sessions/${Uri.encodeComponent(widget.sessionId)}/end-state',
    );
    final endState = _VideoEndState.fromJson(data);
    _ownerVideoLog('end_state.result sessionId=${widget.sessionId} endReason=${endState.endReason} endedBy=${endState.endedByRole} rejoin=${endState.rejoinEligible}');
    return endState;
  }

  Future<String?> _generatePostCallMessage(_VideoEndState endState) async {
    _ownerVideoLog('post_call.generate.request sessionId=${widget.sessionId} endReason=${endState.endReason} rejoin=${endState.rejoinEligible}');
    final data = await _postGatewayJson(
      '/video/sessions/${Uri.encodeComponent(widget.sessionId)}/post-call-message',
      {'endState': endState.toJson()},
    );
    final payload = _asMap(data['payload']);
    final message = payload?['message']?.toString().trim();
    _ownerVideoLog('post_call.generate.result sessionId=${widget.sessionId} hasMessage=${message?.isNotEmpty == true} suggestedAction=${payload?['suggestedAction']}');
    return message == null || message.isEmpty ? null : message;
  }

  Future<Map<String, dynamic>> _getGatewayJson(String path) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      throw const _VideoCallException(
          'Tu sesion expiro. Vuelve a iniciar sesion.');
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
        throw _VideoCallException(_errorMessage(data, response.statusCode));
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
      throw const _VideoCallException(
          'Tu sesion expiro. Vuelve a iniciar sesion.');
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
        throw _VideoCallException(_errorMessage(data, response.statusCode));
      }
      return data;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    final endState = _endState;
    return Scaffold(
      backgroundColor: Colors.black,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment(0.50, -0.00),
            end: Alignment(0.50, 1.00),
            colors: [Color(0xFF141417), Color(0xFF070707)],
          ),
        ),
        child: SafeArea(
          child: _returningToChat
              ? const _VideoStatusView(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: 'Volviendo al chat',
                  message: 'Te llevamos al chat de esta consulta.',
                )
              : _error != null && room == null
              ? _VideoStatusView(
                  icon: Icons.videocam_off_rounded,
                title: endState?.title ?? 'No pude conectar la videollamada',
                  message: _error!,
                actionLabel: endState?.actionLabel ?? 'volver',
                onAction: endState?.rejoinEligible == true
                  ? _rejoinCall
                  : () => endState == null
                    ? context.go('/home')
                    : _openPostCallChat(_postCallAssistantMessage),
                )
              : room == null || _connecting
                  ? const _VideoStatusView(
                      icon: Icons.videocam_rounded,
                      title: 'Conectando videollamada',
                      message: 'Preparando camara y microfono.',
                    )
                  : _ConnectedVideoCall(
                      room: room,
                      roomName: _roomName,
                      micEnabled: _micEnabled,
                      cameraEnabled: _cameraEnabled,
                      ending: _ending,
                      error: _error,
                      onToggleMic: _toggleMicrophone,
                      onToggleCamera: _toggleCamera,
                      onSwitchCamera: _switchCamera,
                      onLeave: _leaveCall,
                    ),
        ),
      ),
    );
  }
}

class _VideoEndState {
  const _VideoEndState({
    required this.sessionId,
    this.sessionStatus,
    this.lifecycleStatus,
    this.endedByRole,
    this.endReason,
    this.roomFinishedAt,
    required this.rejoinEligible,
    this.rejoinUntil,
    this.recommendedAction,
  });

  factory _VideoEndState.fromJson(Map<String, dynamic> json) {
    return _VideoEndState(
      sessionId: json['sessionId']?.toString() ?? '',
      sessionStatus: json['sessionStatus']?.toString(),
      lifecycleStatus: json['lifecycleStatus']?.toString(),
      endedByRole: json['endedByRole']?.toString(),
      endReason: json['endReason']?.toString(),
      roomFinishedAt: json['roomFinishedAt']?.toString(),
      rejoinEligible: json['rejoinEligible'] == true,
      rejoinUntil: json['rejoinUntil']?.toString(),
      recommendedAction: json['recommendedAction']?.toString(),
    );
  }

  final String sessionId;
  final String? sessionStatus;
  final String? lifecycleStatus;
  final String? endedByRole;
  final String? endReason;
  final String? roomFinishedAt;
  final bool rejoinEligible;
  final String? rejoinUntil;
  final String? recommendedAction;

  String get title {
    if (endedByRole == 'vet' || endReason == 'vet_ended') {
      return 'El veterinario terminó la videollamada';
    }
    if (endReason == 'provider_room_finished') {
      return 'La sala de video terminó';
    }
    if (endReason == 'timeout_no_show' || lifecycleStatus == 'timed_out') {
      return 'La videollamada expiró';
    }
    return 'La videollamada terminó';
  }

  String get message {
    if (rejoinEligible) {
      return 'Puedes volver a entrar a la videollamada o continuar el seguimiento por chat.';
    }
    if (endedByRole == 'vet' || endReason == 'vet_ended') {
      return 'Te llevo al chat para continuar el seguimiento con el contexto de la consulta.';
    }
    return 'Puedes continuar el seguimiento desde el chat de la consulta.';
  }

  String get actionLabel => rejoinEligible ? 'volver a entrar' : 'volver al chat';

  bool get shouldReturnToChat {
    return endedByRole == 'vet' ||
        endReason == 'vet_ended' ||
        endReason == 'owner_ended' ||
        endReason == 'admin_ended' ||
        endReason == 'provider_room_finished';
  }

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        if (sessionStatus != null) 'sessionStatus': sessionStatus,
        if (lifecycleStatus != null) 'lifecycleStatus': lifecycleStatus,
        if (endedByRole != null) 'endedByRole': endedByRole,
        if (endReason != null) 'endReason': endReason,
        if (roomFinishedAt != null) 'roomFinishedAt': roomFinishedAt,
        'rejoinEligible': rejoinEligible,
        if (rejoinUntil != null) 'rejoinUntil': rejoinUntil,
        if (recommendedAction != null) 'recommendedAction': recommendedAction,
      };
}

class _ConnectedVideoCall extends StatelessWidget {
  const _ConnectedVideoCall({
    required this.room,
    required this.roomName,
    required this.micEnabled,
    required this.cameraEnabled,
    required this.ending,
    required this.error,
    required this.onToggleMic,
    required this.onToggleCamera,
    required this.onSwitchCamera,
    required this.onLeave,
  });

  final Room room;
  final String? roomName;
  final bool micEnabled;
  final bool cameraEnabled;
  final bool ending;
  final String? error;
  final VoidCallback onToggleMic;
  final VoidCallback onToggleCamera;
  final VoidCallback onSwitchCamera;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final remoteParticipant = _primaryRemoteParticipant(room);
    final localParticipant = room.localParticipant;
    return Stack(
      children: [
        Positioned.fill(
          child: _VideoPane(
            participant: remoteParticipant,
            label: remoteParticipant == null
                ? 'Esperando al veterinario'
                : _participantLabel(remoteParticipant),
            large: true,
          ),
        ),
        Positioned(
          top: 18,
          left: 20,
          right: 20,
          child: _VideoTopBar(roomName: roomName, onBack: onLeave),
        ),
        Positioned(
          right: 18,
          bottom: 118,
          child: _LocalPreview(participant: localParticipant),
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 18,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (error != null) ...[
                _InlineVideoError(message: error!),
                const SizedBox(height: 10),
              ],
              _CallControls(
                micEnabled: micEnabled,
                cameraEnabled: cameraEnabled,
                ending: ending,
                onToggleMic: onToggleMic,
                onToggleCamera: onToggleCamera,
                onSwitchCamera: onSwitchCamera,
                onLeave: onLeave,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VideoPane extends StatelessWidget {
  const _VideoPane(
      {required this.participant, required this.label, this.large = false});

  final Participant? participant;
  final String label;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final track = _activeVideoTrack(participant);
    return DecoratedBox(
      decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: large ? 0.04 : 0.08)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (track != null)
            VideoTrackRenderer(
              track,
              fit: VideoViewFit.cover,
              renderMode: VideoRenderMode.auto,
            )
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.videocam_off_rounded,
                      color: Colors.white.withValues(alpha: 0.68),
                      size: large ? 46 : 24),
                  const SizedBox(height: 10),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.78),
                      fontSize: large ? 16 : 11,
                      fontFamily: 'ABC Diatype',
                      fontWeight: FontWeight.w400,
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

class _LocalPreview extends StatelessWidget {
  const _LocalPreview({required this.participant});

  final LocalParticipant? participant;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black,
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: SizedBox(
          width: 116,
          height: 158,
          child: _VideoPane(
            participant: participant,
            label: 'Tu camara',
          ),
        ),
      ),
    );
  }
}

class _VideoTopBar extends StatelessWidget {
  const _VideoTopBar({required this.roomName, required this.onBack});

  final String? roomName;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_ios_new_rounded,
                  color: Colors.white, size: 22),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Videoconsulta',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontFamily: 'ABC Diatype',
                    fontWeight: FontWeight.w500),
              ),
              if (roomName != null && roomName!.isNotEmpty)
                Text(
                  roomName!,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.42),
                      fontSize: 9,
                      fontFamily: 'ABC Diatype'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CallControls extends StatelessWidget {
  const _CallControls({
    required this.micEnabled,
    required this.cameraEnabled,
    required this.ending,
    required this.onToggleMic,
    required this.onToggleCamera,
    required this.onSwitchCamera,
    required this.onLeave,
  });

  final bool micEnabled;
  final bool cameraEnabled;
  final bool ending;
  final VoidCallback onToggleMic;
  final VoidCallback onToggleCamera;
  final VoidCallback onSwitchCamera;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.44),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _ControlButton(
              icon: micEnabled ? Icons.mic_rounded : Icons.mic_off_rounded,
              active: micEnabled,
              onTap: onToggleMic,
            ),
            const SizedBox(width: 10),
            _ControlButton(
              icon: cameraEnabled
                  ? Icons.videocam_rounded
                  : Icons.videocam_off_rounded,
              active: cameraEnabled,
              onTap: onToggleCamera,
            ),
            const SizedBox(width: 10),
            _ControlButton(
              icon: Icons.cameraswitch_rounded,
              active: true,
              onTap: onSwitchCamera,
            ),
            const SizedBox(width: 10),
            _ControlButton(
              icon: ending
                  ? Icons.hourglass_empty_rounded
                  : Icons.call_end_rounded,
              active: true,
              destructive: true,
              onTap: ending ? null : onLeave,
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton(
      {required this.icon,
      required this.active,
      required this.onTap,
      this.destructive = false});

  final IconData icon;
  final bool active;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: destructive
              ? const Color(0xFFFF4438)
              : active
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.16),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          color: destructive
              ? Colors.white
              : active
                  ? Colors.black
                  : Colors.white,
          size: 22,
        ),
      ),
    );
  }
}

class _VideoStatusView extends StatelessWidget {
  const _VideoStatusView(
      {required this.icon,
      required this.title,
      required this.message,
      this.actionLabel,
      this.onAction});

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 42),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontFamily: 'ABC Diatype',
                  fontWeight: FontWeight.w400),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.62),
                  fontSize: 13,
                  fontFamily: 'ABC Diatype'),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              TextButton(
                  onPressed: onAction,
                  child: Text(actionLabel!,
                      style: const TextStyle(color: Colors.white))),
            ],
          ],
        ),
      ),
    );
  }
}

class _InlineVideoError extends StatelessWidget {
  const _InlineVideoError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFF4438).withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: const Color(0xFFFF4438).withValues(alpha: 0.34)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: Colors.white, fontSize: 11, fontFamily: 'ABC Diatype'),
        ),
      ),
    );
  }
}

RemoteParticipant? _primaryRemoteParticipant(Room room) {
  for (final participant in room.remoteParticipants.values) {
    if (_activeVideoTrack(participant) != null) return participant;
  }
  for (final participant in room.remoteParticipants.values) {
    return participant;
  }
  return null;
}

VideoTrack? _activeVideoTrack(Participant? participant) {
  if (participant == null) return null;
  for (final publication in participant.videoTrackPublications) {
    final track = publication.track;
    if (track is VideoTrack && !publication.muted && !track.muted) return track;
  }
  return null;
}

LocalVideoTrack? _localCameraTrack(LocalParticipant participant) {
  for (final publication in participant.videoTrackPublications) {
    final track = publication.track;
    if (track is LocalVideoTrack) return track;
  }
  return null;
}

bool _hasActiveVideo(Participant? participant) =>
    _activeVideoTrack(participant) != null;

bool _hasActiveAudio(Participant? participant) {
  if (participant == null) return false;
  for (final publication in participant.audioTrackPublications) {
    if (publication.track != null && !publication.muted) return true;
  }
  return false;
}

Future<bool> _isIosSimulator() async {
  if (!Platform.isIOS) return false;
  try {
    final info = await DeviceInfoPlugin().iosInfo;
    return !info.isPhysicalDevice;
  } catch (_) {
    return false;
  }
}

String _participantLabel(Participant participant) {
  if (participant.name.trim().isNotEmpty) return participant.name.trim();
  return participant.identity;
}

Map<String, dynamic>? _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, entry) => MapEntry(key.toString(), entry));
  }
  return null;
}

String _errorMessage(Map<String, dynamic> data, int statusCode) {
  final message = data['message']?.toString();
  if (message != null && message.isNotEmpty) return message;
  final reason = data['reason']?.toString();
  if (reason != null && reason.isNotEmpty) return reason;
  return 'Error del servidor ($statusCode).';
}

class _VideoCallException implements Exception {
  const _VideoCallException(this.message);

  final String message;

  @override
  String toString() => message;
}
