import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/environment.dart';

const _vetAssistantSessionId = 'assistant';
int _vetAssistantMessageSequence = 0;

String _nextVetAssistantMessageId() {
  _vetAssistantMessageSequence += 1;
  return '${DateTime.now().microsecondsSinceEpoch}-$_vetAssistantMessageSequence';
}

class VetChatScreen extends StatefulWidget {
  const VetChatScreen({
    super.key,
    required this.sessionId,
    this.initialMessage,
    this.displayName,
  });

  final String sessionId;
  final String? initialMessage;
  final String? displayName;

  @override
  State<VetChatScreen> createState() => _VetChatScreenState();
}

class _VetChatScreenState extends State<VetChatScreen> {
  final TextEditingController _composerController = TextEditingController();
  final FocusNode _composerFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final List<_VetChatMessage> _assistantMessages = <_VetChatMessage>[];
  final List<_VetChatMessage> _consultMessages = <_VetChatMessage>[];
  RealtimeChannel? _messagesChannel;
  RealtimeChannel? _sessionChannel;
  RealtimeChannel? _roomChannel;
  Timer? _refreshDebounce;
  Timer? _typingDebounce;
  Timer? _remoteTypingClearTimer;
  _VetHandoffBrief? _handoffBrief;
  Object? _consultLoadError;
  bool _sending = false;
  bool _returningDashboard = false;
  bool _consultLoading = false;
  bool _consultClosed = false;
  bool _endingConsult = false;
  bool _ownerOnline = false;
  bool _ownerTyping = false;

  static const _returnDashboardFadeDuration = Duration(milliseconds: 260);

  bool get _isAssistant => widget.sessionId == _vetAssistantSessionId;

  String get _assistantDisplayName {
    final trimmed = widget.displayName?.trim();
    return trimmed == null || trimmed.isEmpty ? 'Doctor' : trimmed;
  }

  @override
  void initState() {
    super.initState();
    if (_isAssistant) {
      final initialMessage = widget.initialMessage?.trim();
      if (initialMessage != null && initialMessage.isNotEmpty) {
        _assistantMessages.add(_VetChatMessage.local(
          role: 'vet',
          content: initialMessage,
        ));
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _composerFocusNode.requestFocus();
        _scrollToBottom();
      });
    } else {
      _composerController.addListener(_handleComposerChanged);
      unawaited(_loadConsultThread());
      _startMessagesRealtime();
      _startSessionRealtime();
      _startRoomSignals();
    }
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    final channel = _messagesChannel;
    if (channel != null) {
      Supabase.instance.client.removeChannel(channel);
    }
    final sessionChannel = _sessionChannel;
    if (sessionChannel != null) {
      Supabase.instance.client.removeChannel(sessionChannel);
    }
    final roomChannel = _roomChannel;
    if (roomChannel != null) {
      unawaited(roomChannel.untrack());
      Supabase.instance.client.removeChannel(roomChannel);
    }
    _typingDebounce?.cancel();
    _remoteTypingClearTimer?.cancel();
    _composerController.dispose();
    _composerFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadConsultThread() async {
    if (mounted) setState(() => _consultLoading = true);
    try {
      final responses = await Future.wait<Map<String, dynamic>>([
        _getGatewayJson(
          '/sessions/${Uri.encodeComponent(widget.sessionId)}/messages?limit=100&sort=stream_order.asc',
        ),
        _getGatewayJson(
          '/sessions/${Uri.encodeComponent(widget.sessionId)}/handoff',
        ),
      ]);
      final messagesResponse = responses[0];
      final handoffResponse = responses[1];
      final messages = _asList(messagesResponse['items'])
              ?.map(_asMap)
              .whereType<Map<String, dynamic>>()
              .map(_VetChatMessage.fromJson)
              .toList() ??
          const <_VetChatMessage>[];
      messages.sort(_compareMessages);
      final session = _asMap(messagesResponse['session']);
      final status = session?['status']?.toString().toLowerCase();
      final receipts = _asList(messagesResponse['receipts']) ?? const [];
      if (!mounted) return;
      setState(() {
        _consultMessages
          ..clear()
          ..addAll(_messagesWithReceipts(messages, receipts));
        _handoffBrief = _VetHandoffBrief.fromJson(handoffResponse);
        _consultClosed = _isClosedStatus(status);
        _consultLoadError = null;
      });
      _markVisibleMessagesRead();
      _scrollToBottom();
    } catch (error) {
      if (!mounted) return;
      setState(() => _consultLoadError = error);
    } finally {
      if (mounted) setState(() => _consultLoading = false);
    }
  }

  void _startMessagesRealtime() {
    final normalizedSessionId = widget.sessionId.trim();
    if (normalizedSessionId.isEmpty) return;
    final channel =
        Supabase.instance.client.channel('vet-chat:$normalizedSessionId');
    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'session_id',
            value: normalizedSessionId,
          ),
          callback: (payload) {
            final record = payload.newRecord.isNotEmpty
                ? payload.newRecord
                : payload.oldRecord;
            final message = _VetChatMessage.fromJson(record);
            if (message.id.isEmpty) {
              _scheduleRefresh();
              return;
            }
            _upsertConsultMessage(message);
          },
        )
        .subscribe();
    _messagesChannel = channel;
  }

  void _startSessionRealtime() {
    final normalizedSessionId = widget.sessionId.trim();
    if (normalizedSessionId.isEmpty) return;
    final channel = Supabase.instance.client
        .channel('vet-chat-session:$normalizedSessionId');
    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'chat_sessions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: normalizedSessionId,
          ),
          callback: (payload) {
            final status =
                payload.newRecord['status']?.toString().toLowerCase();
            if (_isClosedStatus(status) && mounted) {
              setState(() => _consultClosed = true);
            }
          },
        )
        .subscribe();
    _sessionChannel = channel;
  }

  void _startRoomSignals() {
    final normalizedSessionId = widget.sessionId.trim();
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (normalizedSessionId.isEmpty || userId == null || userId.isEmpty) {
      return;
    }
    final channel = Supabase.instance.client.channel(
      'consult-room:$normalizedSessionId',
      opts: RealtimeChannelConfig(private: true, key: userId),
    );
    channel
        .onBroadcast(
          event: 'typing',
          callback: (payload) {
            if (payload['role']?.toString() != 'user') return;
            final typing = payload['typing'] == true;
            if (!mounted) return;
            setState(() => _ownerTyping = typing);
            _remoteTypingClearTimer?.cancel();
            if (typing) {
              _remoteTypingClearTimer = Timer(
                const Duration(seconds: 3),
                () {
                  if (mounted) setState(() => _ownerTyping = false);
                },
              );
            }
          },
        )
        .onBroadcast(
          event: 'receipts',
          callback: (payload) {
            final receipts = _asList(payload['receipts']) ?? const [];
            for (final receiptValue in receipts) {
              final receipt = _asMap(receiptValue);
              if (receipt != null) _applyReceipt(receipt);
            }
          },
        )
        .onPresenceSync((_) => _syncOwnerPresence(channel))
        .subscribe((status, [_]) {
      if (status == RealtimeSubscribeStatus.subscribed) {
        unawaited(channel.track({
          'role': 'vet',
          'userId': userId,
          'onlineAt': DateTime.now().toIso8601String(),
        }));
      }
    });
    _roomChannel = channel;
  }

  void _syncOwnerPresence(RealtimeChannel channel) {
    final online = channel.presenceState().any((state) => state.presences.any(
          (presence) => presence.payload['role']?.toString() == 'user',
        ));
    if (mounted) setState(() => _ownerOnline = online);
  }

  void _handleComposerChanged() {
    if (_isAssistant || _consultClosed || _roomChannel == null) return;
    _typingDebounce?.cancel();
    final isTyping = _composerController.text.trim().isNotEmpty;
    _typingDebounce = Timer(const Duration(milliseconds: 300), () {
      final channel = _roomChannel;
      if (channel == null) return;
      unawaited(channel.sendBroadcastMessage(
        event: 'typing',
        payload: {
          'role': 'vet',
          'typing': isTyping,
          'at': DateTime.now().toIso8601String(),
        },
      ));
    });
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce =
        Timer(const Duration(milliseconds: 450), _refreshMessages);
  }

  void _refreshMessages() {
    if (!mounted) return;
    unawaited(_loadConsultThread());
  }

  void _upsertConsultMessage(_VetChatMessage message) {
    if (!mounted) return;
    setState(() {
      final index =
          _consultMessages.indexWhere((existing) => existing.id == message.id);
      if (index >= 0) {
        _consultMessages[index] =
            message.withReceiptFrom(_consultMessages[index]);
      } else {
        _consultMessages.add(message);
      }
      _consultMessages.sort(_compareMessages);
    });
    if (message.role != 'vet') _markVisibleMessagesRead();
    _scrollToBottom();
  }

  List<_VetChatMessage> _messagesWithReceipts(
    List<_VetChatMessage> messages,
    List<dynamic> receipts,
  ) {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    return messages.map((message) {
      if (message.role != 'vet') return message;
      var delivered = message.deliveredByOther;
      var read = message.readByOther;
      for (final receiptValue in receipts) {
        final receipt = _asMap(receiptValue);
        if (receipt == null ||
            receipt['message_id']?.toString() != message.id) {
          continue;
        }
        if (receipt['user_id']?.toString() == currentUserId) continue;
        delivered = delivered || receipt['delivered_at'] != null;
        read = read || receipt['read_at'] != null;
      }
      return message.copyWith(deliveredByOther: delivered, readByOther: read);
    }).toList(growable: false);
  }

  void _applyReceipt(Map<String, dynamic> receipt) {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (receipt['user_id']?.toString() == currentUserId) return;
    final messageId = receipt['message_id']?.toString() ?? '';
    if (messageId.isEmpty || !mounted) return;
    setState(() {
      final index =
          _consultMessages.indexWhere((message) => message.id == messageId);
      if (index < 0 || _consultMessages[index].role != 'vet') return;
      _consultMessages[index] = _consultMessages[index].copyWith(
        deliveredByOther: receipt['delivered_at'] != null,
        readByOther: receipt['read_at'] != null,
      );
    });
  }

  void _markVisibleMessagesRead() {
    final lastStreamOrder = _consultMessages
        .where((message) => message.role != 'vet')
        .map((message) => message.streamOrder ?? 0)
        .fold<int>(0, (max, value) => value > max ? value : max);
    if (lastStreamOrder <= 0) return;
    unawaited(_postGatewayJson(
      '/sessions/${Uri.encodeComponent(widget.sessionId)}/messages/read',
      {'lastStreamOrder': lastStreamOrder},
    ));
  }

  int _compareMessages(_VetChatMessage a, _VetChatMessage b) {
    final aOrder = a.streamOrder;
    final bOrder = b.streamOrder;
    if (aOrder != null && bOrder != null && aOrder != bOrder) {
      return aOrder.compareTo(bOrder);
    }
    final aTime = a.createdAt;
    final bTime = b.createdAt;
    if (aTime != null && bTime != null) return aTime.compareTo(bTime);
    return a.id.compareTo(b.id);
  }

  bool _isClosedStatus(String? status) {
    return status == 'completed' || status == 'canceled' || status == 'no_show';
  }

  Future<void> _sendMessage() async {
    if (_isAssistant) {
      _sendAssistantMessage();
      return;
    }
    final text = _composerController.text.trim();
    if (text.isEmpty || _sending || _consultClosed) return;
    final clientKey =
        'vet-${DateTime.now().microsecondsSinceEpoch}-${_nextVetAssistantMessageId()}';
    setState(() => _sending = true);
    try {
      final response = await _postGatewayJson(
          '/sessions/${Uri.encodeComponent(widget.sessionId)}/messages', {
        'content': text,
        'clientKey': clientKey,
      });
      _composerController.clear();
      final message = _asMap(response['message']);
      if (message != null) {
        _upsertConsultMessage(_VetChatMessage.fromJson(message));
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo enviar: $error')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _endConsult() async {
    if (_isAssistant || _endingConsult || _consultClosed) return;
    setState(() => _endingConsult = true);
    try {
      await _postGatewayJson(
        '/vets/me/consults/${Uri.encodeComponent(widget.sessionId)}/end',
        const <String, dynamic>{},
      );
      if (!mounted) return;
      setState(() => _consultClosed = true);
      await _returnDashboard();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo cerrar: $error')),
      );
    } finally {
      if (mounted) setState(() => _endingConsult = false);
    }
  }

  void _sendAssistantMessage() {
    final text = _composerController.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _assistantMessages.add(_VetChatMessage.local(
        role: 'vet',
        content: text,
      ));
      _composerController.clear();
    });
    _scrollToBottom();
  }

  Future<void> _returnDashboard() async {
    if (_returningDashboard) return;
    _refreshDebounce?.cancel();
    _composerFocusNode.unfocus();
    setState(() => _returningDashboard = true);
    await Future<void>.delayed(_returnDashboardFadeDuration);
    if (!mounted) return;
    if (_isAssistant) {
      context.go('/dashboard');
      return;
    }
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/dashboard');
    }
  }

  Future<Map<String, dynamic>> _getGatewayJson(String path) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      throw const _VetChatException(
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
        throw _VetChatException(_errorMessage(data, response.statusCode));
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
      throw const _VetChatException(
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
        throw _VetChatException(_errorMessage(data, response.statusCode));
      }
      return data;
    } finally {
      client.close(force: true);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final thread = _isAssistant
        ? _buildAssistantThread(context)
        : _buildConsultThread(context);

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment(0.50, -0.00),
            end: Alignment(0.50, 1.00),
            colors: [Color(0xFF141417), Color(0xFF070707)],
          ),
        ),
        child: IgnorePointer(
          ignoring: _returningDashboard,
          child: AnimatedOpacity(
            duration: _returnDashboardFadeDuration,
            curve: Curves.easeOutCubic,
            opacity: _returningDashboard ? 0 : 1,
            child: thread,
          ),
        ),
      ),
    );
  }

  Widget _buildConsultThread(BuildContext context) {
    final hasHandoff = _handoffBrief != null;
    final itemCount = (hasHandoff ? 1 : 0) + _consultMessages.length;
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _ChatTopBar(
            sessionId: widget.sessionId,
            ownerOnline: _ownerOnline,
            ownerTyping: _ownerTyping,
            onBack: () => unawaited(_returnDashboard()),
            onEnd: _consultClosed ? null : () => unawaited(_endConsult()),
            ending: _endingConsult,
          ),
          Expanded(
            child: _consultLoading && itemCount == 0
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.white))
                : _consultLoadError != null && itemCount == 0
                    ? _ChatStatusView(
                        icon: Icons.chat_bubble_outline_rounded,
                        title: 'No pude cargar el chat',
                        message: _consultLoadError.toString(),
                        onRetry: _refreshMessages,
                      )
                    : itemCount == 0
                        ? const _ChatStatusView(
                            icon: Icons.forum_outlined,
                            title: 'Chat listo',
                            message: 'Aún no hay mensajes en esta consulta.',
                          )
                        : ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
                            itemCount: itemCount,
                            itemBuilder: (context, index) {
                              if (hasHandoff && index == 0) {
                                return _HandoffBriefCard(
                                    handoff: _handoffBrief!);
                              }
                              final messageIndex = index - (hasHandoff ? 1 : 0);
                              return _ChatBubble(
                                  message: _consultMessages[messageIndex]);
                            },
                          ),
          ),
          _ChatComposer(
            controller: _composerController,
            focusNode: _composerFocusNode,
            sending: _sending || _endingConsult || _consultClosed,
            includeBottomInset: true,
            onSend: _sendMessage,
          ),
        ],
      ),
    );
  }

  Widget _buildAssistantThread(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final topChromeHeight = topInset + 90;
    final topFadeHeight = topInset + 132;
    final bottomFadeHeight = bottomInset + 150;
    final messageList = ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(18, topChromeHeight, 18, bottomInset + 102),
      itemCount: 1 + _assistantMessages.length,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _VetAssistantIntro(displayName: _assistantDisplayName);
        }
        final message = _assistantMessages[index - 1];
        return _AnimatedVetMessageEntry(
          key: ValueKey(message.id),
          child: _ChatBubble(message: message),
        );
      },
    );

    return Stack(
      children: [
        Positioned.fill(
          child: _MessageOpacityFade(
            topFadeHeight: topFadeHeight,
            bottomFadeHeight: bottomFadeHeight,
            child: messageList,
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: _AssistantChatHeader(
              onBack: () => unawaited(_returnDashboard()),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _ChatComposer(
            controller: _composerController,
            focusNode: _composerFocusNode,
            sending: _sending,
            includeBottomInset: true,
            onSend: _sendMessage,
          ),
        ),
      ],
    );
  }
}

class _MessageOpacityFade extends StatelessWidget {
  const _MessageOpacityFade({
    required this.child,
    required this.topFadeHeight,
    required this.bottomFadeHeight,
  });

  final Widget child;
  final double topFadeHeight;
  final double bottomFadeHeight;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final topStop =
            (topFadeHeight / bounds.height).clamp(0.12, 0.32).toDouble();
        final bottomStart = (1 - (bottomFadeHeight / bounds.height))
            .clamp(0.68, 0.90)
            .toDouble();
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: [0, topStop, bottomStart, 1],
        ).createShader(bounds);
      },
      child: child,
    );
  }
}

class _VetAssistantIntro extends StatelessWidget {
  const _VetAssistantIntro({required this.displayName});

  final String displayName;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 30),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 332,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '¡Hola, $displayName!',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontFamily: 'ABC Diatype',
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '¿Qué necesitas revisar hoy?',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontFamily: 'ABC Diatype',
                  fontWeight: FontWeight.w400,
                  height: 1.10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssistantChatHeader extends StatelessWidget {
  const _AssistantChatHeader({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 24, 18, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          onTap: onBack,
          behavior: HitTestBehavior.opaque,
          child: const SizedBox(
            width: 24,
            height: 42,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Icon(
                Icons.arrow_back_ios_new_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AnimatedVetMessageEntry extends StatelessWidget {
  const _AnimatedVetMessageEntry({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 18 * (1 - value)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

class _ChatTopBar extends StatelessWidget {
  const _ChatTopBar({
    required this.sessionId,
    required this.ownerOnline,
    required this.ownerTyping,
    required this.onBack,
    required this.onEnd,
    required this.ending,
  });

  final String sessionId;
  final bool ownerOnline;
  final bool ownerTyping;
  final VoidCallback onBack;
  final VoidCallback? onEnd;
  final bool ending;

  @override
  Widget build(BuildContext context) {
    final shortId =
        sessionId.length > 8 ? sessionId.substring(0, 8) : sessionId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 18, 14),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            tooltip: 'volver',
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'chat de consulta',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontFamily: 'ABC Diatype',
                      fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  ownerTyping
                      ? 'tutor escribiendo...'
                      : ownerOnline
                          ? 'tutor en línea · sesión $shortId'
                          : 'sesión $shortId',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.48),
                      fontSize: 12,
                      fontFamily: 'ABC Diatype'),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: ending ? null : onEnd,
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              disabledForegroundColor: Colors.white.withValues(alpha: 0.35),
            ),
            child: Text(ending ? 'cerrando...' : 'cerrar'),
          ),
        ],
      ),
    );
  }
}

class _HandoffBriefCard extends StatelessWidget {
  const _HandoffBriefCard({required this.handoff});

  final _VetHandoffBrief handoff;

  @override
  Widget build(BuildContext context) {
    final sections = <Widget>[
      if (handoff.summaryText.isNotEmpty)
        Text(
          handoff.summaryText,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontFamily: 'ABC Diatype',
            height: 1.32,
          ),
        ),
      if (handoff.redFlags.isNotEmpty)
        _HandoffList(label: 'alertas', items: handoff.redFlags),
      if (handoff.reportedSigns.isNotEmpty)
        _HandoffList(label: 'signos reportados', items: handoff.reportedSigns),
      if (handoff.recommendedFirstChecks.isNotEmpty)
        _HandoffList(
          label: 'primeras revisiones',
          items: handoff.recommendedFirstChecks,
        ),
    ];

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome_rounded,
                  color: Colors.white, size: 16),
              const SizedBox(width: 8),
              const Text(
                'brief de IA',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontFamily: 'ABC Diatype',
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (handoff.urgency.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  handoff.urgency,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.52),
                    fontSize: 11,
                    fontFamily: 'ABC Diatype',
                  ),
                ),
              ],
            ],
          ),
          for (final section in sections) ...[
            const SizedBox(height: 10),
            section,
          ],
        ],
      ),
    );
  }
}

class _HandoffList extends StatelessWidget {
  const _HandoffList({required this.label, required this.items});

  final String label;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.52),
            fontSize: 11,
            fontFamily: 'ABC Diatype',
          ),
        ),
        const SizedBox(height: 5),
        for (final item in items.take(4))
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '- $item',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontFamily: 'ABC Diatype',
                height: 1.28,
              ),
            ),
          ),
      ],
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.message});

  final _VetChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isVet = message.role == 'vet';
    final isAi = message.role == 'ai';
    final messageStyle = TextStyle(
      color: isVet ? Colors.black : Colors.white,
      fontSize: 14,
      fontFamily: 'ABC Diatype',
      height: 1.28,
    );
    return Align(
      alignment: isVet ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 310),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 10),
        decoration: BoxDecoration(
          color: isVet
              ? Colors.white
              : Colors.white.withValues(alpha: isAi ? 0.12 : 0.07),
          borderRadius: BorderRadius.circular(18),
          border: isVet
              ? null
              : Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            isAi
                ? _AiMessageContent(
                    content: message.content, style: messageStyle)
                : Text(message.content, style: messageStyle),
            const SizedBox(height: 6),
            Text(
              message.label,
              style: TextStyle(
                color: isVet
                    ? Colors.black.withValues(alpha: 0.45)
                    : Colors.white.withValues(alpha: 0.42),
                fontSize: 10,
                fontFamily: 'ABC Diatype',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _AiMessageBlockType { paragraph, numberedList, bulletList, safetyNote }

class _AiMessageBlock {
  const _AiMessageBlock({
    required this.type,
    required this.text,
    required this.items,
  });

  static _AiMessageBlock? fromJson(Map<String, dynamic> json) {
    final type = switch (json['type']?.toString()) {
      'paragraph' => _AiMessageBlockType.paragraph,
      'numbered_list' => _AiMessageBlockType.numberedList,
      'bullet_list' => _AiMessageBlockType.bulletList,
      'safety_note' => _AiMessageBlockType.safetyNote,
      _ => null,
    };
    if (type == null) return null;
    final items = (_asList(json['items']) ?? const [])
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    if (type == _AiMessageBlockType.numberedList ||
        type == _AiMessageBlockType.bulletList) {
      if (items.isEmpty) return null;
      return _AiMessageBlock(type: type, text: null, items: items);
    }
    final text = json['text']?.toString().trim();
    if (text == null || text.isEmpty) return null;
    return _AiMessageBlock(type: type, text: text, items: const <String>[]);
  }

  final _AiMessageBlockType type;
  final String? text;
  final List<String> items;
}

class _AiMessageContent extends StatelessWidget {
  const _AiMessageContent({required this.content, required this.style});

  final String content;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final payload = _AiMessagePayload.tryParse(content);
    if (payload.blocks.isEmpty) {
      return Text(_readableAiText(payload.message), style: style);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < payload.blocks.length; index++)
          Padding(
            padding: EdgeInsets.only(
                bottom: index == payload.blocks.length - 1 ? 0 : 8),
            child: _AiMessageBlockView(
              block: payload.blocks[index],
              style: style,
            ),
          ),
      ],
    );
  }
}

class _AiMessagePayload {
  const _AiMessagePayload({required this.message, required this.blocks});

  static _AiMessagePayload tryParse(String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      return const _AiMessagePayload(message: '', blocks: <_AiMessageBlock>[]);
    }
    try {
      final decoded = jsonDecode(trimmed);
      final root = _asMap(decoded);
      final payload = _asMap(root?['payload']) ?? root;
      if (payload == null) {
        return _AiMessagePayload(
            message: trimmed, blocks: const <_AiMessageBlock>[]);
      }
      final formatVersion = _toInt(payload['formatVersion']) ?? 0;
      final blocks = formatVersion == 1
          ? (_asList(payload['displayBlocks']) ?? const [])
              .map(_asMap)
              .whereType<Map<String, dynamic>>()
              .map(_AiMessageBlock.fromJson)
              .whereType<_AiMessageBlock>()
              .toList(growable: false)
          : const <_AiMessageBlock>[];
      return _AiMessagePayload(
        message: payload['message']?.toString() ?? trimmed,
        blocks: blocks,
      );
    } catch (_) {
      return _AiMessagePayload(
          message: trimmed, blocks: const <_AiMessageBlock>[]);
    }
  }

  final String message;
  final List<_AiMessageBlock> blocks;
}

class _AiMessageBlockView extends StatelessWidget {
  const _AiMessageBlockView({required this.block, required this.style});

  final _AiMessageBlock block;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    switch (block.type) {
      case _AiMessageBlockType.paragraph:
        return Text(block.text ?? '', style: style);
      case _AiMessageBlockType.safetyNote:
        return Text(
          block.text ?? '',
          style: style.copyWith(
            color: style.color?.withValues(alpha: 0.92),
            fontWeight: FontWeight.w500,
          ),
        );
      case _AiMessageBlockType.numberedList:
        return _AiMessageList(items: block.items, numbered: true, style: style);
      case _AiMessageBlockType.bulletList:
        return _AiMessageList(
            items: block.items, numbered: false, style: style);
    }
  }
}

class _AiMessageList extends StatelessWidget {
  const _AiMessageList({
    required this.items,
    required this.numbered,
    required this.style,
  });

  final List<String> items;
  final bool numbered;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final markerStyle = style.copyWith(
      color: style.color?.withValues(alpha: 0.68),
      fontWeight: FontWeight.w500,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < items.length; index++)
          Padding(
            padding: EdgeInsets.only(bottom: index == items.length - 1 ? 0 : 6),
            child: _AiMessageListRow(
              marker: numbered ? '${index + 1}.' : null,
              text: items[index],
              style: style,
              markerStyle: markerStyle,
            ),
          ),
      ],
    );
  }
}

class _AiMessageListRow extends StatelessWidget {
  const _AiMessageListRow({
    required this.marker,
    required this.text,
    required this.style,
    required this.markerStyle,
  });

  final String? marker;
  final String text;
  final TextStyle style;
  final TextStyle markerStyle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 24,
          child: marker == null
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                    alignment: Alignment.topRight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: (style.color ?? Colors.white)
                            .withValues(alpha: 0.68),
                        shape: BoxShape.circle,
                      ),
                      child: const SizedBox(width: 4, height: 4),
                    ),
                  ),
                )
              : Text(marker!, textAlign: TextAlign.right, style: markerStyle),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: style)),
      ],
    );
  }
}

String _readableAiText(String text) {
  var formatted = text.trim().replaceAll('**', '').replaceAll('__', '');
  formatted = formatted.replaceAll(RegExp(r'[ \t]+\n'), '\n');
  formatted = formatted.replaceAll(RegExp(r'\n[ \t]+'), '\n');
  formatted = formatted.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  formatted = formatted.replaceAllMapped(
    RegExp(r'(:)\s+(\d+[.)]\s)'),
    (match) => '${match[1]}\n${match[2]}',
  );
  formatted = formatted.replaceAllMapped(
    RegExp(r'([^\n])\n+(\d+[.)]\s)'),
    (match) => '${match[1]}\n${match[2]}',
  );
  formatted = formatted.replaceAllMapped(
    RegExp(r'\n{2,}(\d+[.)]\s)'),
    (match) => '\n${match[1]}',
  );
  return formatted;
}

class _ChatComposer extends StatelessWidget {
  const _ChatComposer({
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.includeBottomInset,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final bool includeBottomInset;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final bottomInset =
        includeBottomInset ? MediaQuery.paddingOf(context).bottom : 0.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 8, 18, 14 + bottomInset),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 46, maxHeight: 150),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withValues(alpha: 0.055)),
          ),
          child: Padding(
            padding:
                const EdgeInsets.only(left: 18, right: 6, top: 3, bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    enabled: !sending,
                    cursorColor: Colors.white,
                    keyboardType: TextInputType.multiline,
                    textCapitalization: TextCapitalization.sentences,
                    minLines: 1,
                    maxLines: 6,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => onSend(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontFamily: 'ABC Diatype',
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      height: 1.25,
                      letterSpacing: 0,
                    ),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: sending ? 'Pensando...' : 'escribir mensaje...',
                      hintStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.32),
                        fontFamily: 'ABC Diatype',
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        height: 1.25,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 1),
                  child: IconButton.filled(
                    onPressed: sending ? null : onSend,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white,
                      disabledBackgroundColor:
                          Colors.white.withValues(alpha: 0.25),
                      foregroundColor: Colors.black,
                      fixedSize: const Size(38, 38),
                    ),
                    icon: sending
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : const Icon(Icons.arrow_upward_rounded, size: 19),
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

class _ChatStatusView extends StatelessWidget {
  const _ChatStatusView(
      {required this.icon,
      required this.title,
      required this.message,
      this.onRetry});

  final IconData icon;
  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 38),
            const SizedBox(height: 12),
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontFamily: 'ABC Diatype')),
            const SizedBox(height: 6),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.58),
                    fontSize: 13,
                    fontFamily: 'ABC Diatype')),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              TextButton(onPressed: onRetry, child: const Text('reintentar')),
            ],
          ],
        ),
      ),
    );
  }
}

class _VetChatMessage {
  const _VetChatMessage(
      {required this.id,
      required this.senderId,
      required this.role,
      required this.content,
      required this.createdAt,
      this.clientKey,
      this.streamOrder,
      this.deliveredByOther = false,
      this.readByOther = false});

  factory _VetChatMessage.fromJson(Map<String, dynamic> json) {
    return _VetChatMessage(
      id: json['id']?.toString() ?? '',
      senderId: json['sender_id']?.toString(),
      role: json['role']?.toString().toLowerCase() ?? 'user',
      content: json['content']?.toString() ?? '',
      createdAt: _parseDateTime(json['created_at']),
      clientKey: json['client_key']?.toString(),
      streamOrder: _asInt(json['stream_order']),
    );
  }

  factory _VetChatMessage.local(
      {required String role, required String content}) {
    return _VetChatMessage(
      id: _nextVetAssistantMessageId(),
      senderId: Supabase.instance.client.auth.currentUser?.id,
      role: role,
      content: content,
      createdAt: DateTime.now(),
      streamOrder: null,
    );
  }

  final String id;
  final String? senderId;
  final String role;
  final String content;
  final DateTime? createdAt;
  final String? clientKey;
  final int? streamOrder;
  final bool deliveredByOther;
  final bool readByOther;

  _VetChatMessage copyWith({
    bool? deliveredByOther,
    bool? readByOther,
  }) {
    return _VetChatMessage(
      id: id,
      senderId: senderId,
      role: role,
      content: content,
      createdAt: createdAt,
      clientKey: clientKey,
      streamOrder: streamOrder,
      deliveredByOther: deliveredByOther ?? this.deliveredByOther,
      readByOther: readByOther ?? this.readByOther,
    );
  }

  _VetChatMessage withReceiptFrom(_VetChatMessage previous) {
    return copyWith(
      deliveredByOther: previous.deliveredByOther,
      readByOther: previous.readByOther,
    );
  }

  String get label {
    final who = role == 'vet'
        ? 'tú'
        : role == 'ai'
            ? 'asistente'
            : 'tutor';
    final receipt = role == 'vet'
        ? readByOther
            ? ' · leído'
            : deliveredByOther
                ? ' · entregado'
                : ''
        : '';
    if (createdAt == null) return '$who$receipt';
    final hour = createdAt!.hour.toString().padLeft(2, '0');
    final minute = createdAt!.minute.toString().padLeft(2, '0');
    return '$who · $hour:$minute$receipt';
  }
}

class _VetHandoffBrief {
  const _VetHandoffBrief({
    required this.summaryText,
    required this.urgency,
    required this.reportedSigns,
    required this.redFlags,
    required this.recommendedFirstChecks,
  });

  factory _VetHandoffBrief.fromJson(Map<String, dynamic> json) {
    final handoff = _asMap(json['handoff']) ?? _asMap(json['data']) ?? json;
    final summaryText = handoff['summary_text']?.toString().trim() ??
        handoff['summaryText']?.toString().trim() ??
        handoff['summary']?.toString().trim() ??
        '';
    final urgency = handoff['urgency']?.toString().trim() ?? '';
    final reportedSigns = _stringList(
      handoff['reported_signs'] ?? handoff['reportedSigns'],
    );
    final redFlags = _stringList(
      handoff['red_flags'] ?? handoff['redFlags'],
    );
    final recommendedFirstChecks = _stringList(
      handoff['recommended_first_checks'] ?? handoff['recommendedFirstChecks'],
    );
    return _VetHandoffBrief(
      summaryText: summaryText,
      urgency: urgency,
      reportedSigns: reportedSigns,
      redFlags: redFlags,
      recommendedFirstChecks: recommendedFirstChecks,
    );
  }

  final String summaryText;
  final String urgency;
  final List<String> reportedSigns;
  final List<String> redFlags;
  final List<String> recommendedFirstChecks;

  bool get isEmpty =>
      summaryText.isEmpty &&
      reportedSigns.isEmpty &&
      redFlags.isEmpty &&
      recommendedFirstChecks.isEmpty;
}

Map<String, dynamic>? _asMap(Object? value) {
  return value is Map
      ? value.map((key, val) => MapEntry(key.toString(), val))
      : null;
}

List<dynamic>? _asList(Object? value) => value is List ? value : null;

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

List<String> _stringList(Object? value) {
  final list = _asList(value);
  if (list == null) return const <String>[];
  return list
      .map((item) => item?.toString().trim() ?? '')
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

int? _toInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

DateTime? _parseDateTime(Object? value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString())?.toLocal();
}

String _errorMessage(Map<String, dynamic> data, int statusCode) {
  final message = data['message']?.toString();
  if (message != null && message.isNotEmpty) return message;
  final error = data['error']?.toString();
  if (error != null && error.isNotEmpty) return error;
  return 'error_$statusCode';
}

class _VetChatException implements Exception {
  const _VetChatException(this.message);

  final String message;

  @override
  String toString() => message;
}
