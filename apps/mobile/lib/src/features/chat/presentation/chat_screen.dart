import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/environment.dart';

const _aiChatDryRun = bool.fromEnvironment('CAV_AI_CHAT_DRY_RUN');

void _aiChatLog(String message) {
  debugPrint('[AIChat][Mobile] $message');
}

String _preview(String? value, {int max = 180}) {
  final normalized = (value ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.length <= max) return normalized;
  return '${normalized.substring(0, max)}...';
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.sessionId,
    this.initialMessage,
    this.embedded = false,
  });

  final String sessionId;
  final String? initialMessage;
  final bool embedded;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputCtrl = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  final _messages = <_ChatMessage>[
    _ChatMessage.assistant(
      'Cuéntame qué está pasando con tu caballo y te ayudo a encontrar el veterinario adecuado.',
      includeInHistory: false,
    ),
  ];

  late final String _conversationId;
  bool _isSending = false;

  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  @override
  void initState() {
    super.initState();
    _conversationId = 'mobile-${DateTime.now().microsecondsSinceEpoch}';
    _aiChatLog(
      'init sessionId=${widget.sessionId} sessionIdLooksUuid=${_uuidOrNull(widget.sessionId) != null} '
      'conversationId=$_conversationId initialMessagePresent=${widget.initialMessage?.trim().isNotEmpty == true} '
      'initialMessageLength=${widget.initialMessage?.trim().length ?? 0} apiBaseUrl=${Environment.apiBaseUrl} dryRun=$_aiChatDryRun',
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final initialMessage = widget.initialMessage?.trim();
      if (initialMessage != null && initialMessage.isNotEmpty) {
        _aiChatLog('postFrame auto-sending initial message preview="${_preview(initialMessage)}"');
        _sendUserMessage(initialMessage);
      } else {
        _aiChatLog('postFrame no initial message; focusing composer');
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _aiChatLog('dispose conversationId=$_conversationId totalMessages=${_messages.length}');
    _inputCtrl.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _sendComposerMessage() {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) {
      _aiChatLog('composer send ignored: empty input');
      return;
    }
    if (_isSending) {
      _aiChatLog('composer send ignored: request already in flight');
      return;
    }
    _aiChatLog('composer send accepted length=${text.length} preview="${_preview(text)}"');
    _inputCtrl.clear();
    _sendUserMessage(text);
  }

  Future<void> _sendUserMessage(String text) async {
    if (_isSending) {
      _aiChatLog('sendUserMessage ignored while sending preview="${_preview(text)}"');
      return;
    }
    final history = _historyForApi();
    _aiChatLog(
      'sendUserMessage start conversationId=$_conversationId messageLength=${text.length} '
      'historyCount=${history.length} visibleMessages=${_messages.length}',
    );
    setState(() {
      _messages.add(_ChatMessage.user(text));
      _isSending = true;
    });
    _aiChatLog('sendUserMessage state updated: user bubble appended isSending=$_isSending');
    _scrollToBottom();

    try {
      final response = await _runAiTurn(text, history);
      _aiChatLog('sendUserMessage raw response keys=${response.keys.join(',')}');
      final result = _AiChatTurnResult.fromJson(response);
      _aiChatLog(
        'sendUserMessage parsed result urgency=${result.payload.urgency} '
        'recommendedService=${result.payload.recommendedService} actionLabel=${result.payload.actionLabel} '
        'specialty=${result.specialtyName} vet=${result.vetName} remaining=${result.remaining}',
      );
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage.assistant(result.payload.message, result: result));
        _isSending = false;
      });
      _aiChatLog('sendUserMessage success: assistant bubble appended totalMessages=${_messages.length}');
      _scrollToBottom();
    } catch (error) {
      _aiChatLog('sendUserMessage failed: ${error.runtimeType} $error');
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage.assistant(_friendlyError(error), includeInHistory: false));
        _isSending = false;
      });
      _aiChatLog('sendUserMessage error bubble appended totalMessages=${_messages.length}');
      _scrollToBottom();
    }
  }

  Future<Map<String, dynamic>> _runAiTurn(
    String message,
    List<Map<String, String>> history,
  ) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    _aiChatLog('runAiTurn auth snapshot tokenPresent=${token?.isNotEmpty == true} userId=$userId');
    if (token == null || token.isEmpty) {
      _aiChatLog('runAiTurn aborted: missing Supabase access token');
      throw const _ChatApiException('Tu sesión expiró. Vuelve a iniciar sesión.');
    }

    final sessionId = _uuidOrNull(widget.sessionId);
    _aiChatLog('runAiTurn session routing raw=${widget.sessionId} normalized=${sessionId ?? 'none'}');
    final body = <String, dynamic>{
      'conversationId': _conversationId,
      'message': message,
      'messages': history,
      if (sessionId != null) 'sessionId': sessionId,
      if (_aiChatDryRun) 'dryRun': true,
    };

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final startedAt = DateTime.now();
    try {
      final uri = Uri.parse('${Environment.apiBaseUrl}/ai/chat/turn');
      _aiChatLog(
        'runAiTurn POST $uri bodySummary={conversationId:$_conversationId, messageLength:${message.length}, '
        'historyCount:${history.length}, sessionId:${sessionId ?? 'none'}, dryRun:$_aiChatDryRun}',
      );
      final request = await client.postUrl(uri).timeout(const Duration(seconds: 10));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.add(utf8.encode(jsonEncode(body)));
      _aiChatLog('runAiTurn request sent; awaiting gateway response');

      final response = await request.close().timeout(const Duration(seconds: 45));
      final rawBody = await utf8.decoder.bind(response).join();
      final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
      _aiChatLog(
        'runAiTurn response status=${response.statusCode} elapsedMs=$elapsedMs bodyLength=${rawBody.length} '
        'bodyPreview="${_preview(rawBody, max: 500)}"',
      );
      final decoded = rawBody.trim().isEmpty ? <String, dynamic>{} : jsonDecode(rawBody);
      final data = _asMap(decoded) ?? <String, dynamic>{};
      _aiChatLog('runAiTurn decoded response mapKeys=${data.keys.join(',')}');

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _aiChatLog('runAiTurn gateway returned error status=${response.statusCode} message=${_errorMessage(data, response.statusCode)}');
        throw _ChatApiException(_errorMessage(data, response.statusCode));
      }
      return data;
    } on TimeoutException {
      _aiChatLog('runAiTurn timeout after ${DateTime.now().difference(startedAt).inMilliseconds}ms');
      throw const _ChatApiException('La conexión tardó demasiado. Inténtalo otra vez.');
    } on FormatException catch (error) {
      _aiChatLog('runAiTurn JSON decode failed: $error');
      throw const _ChatApiException('El asistente respondió con datos inválidos.');
    } on SocketException {
      _aiChatLog('runAiTurn socket error while reaching ${Environment.apiBaseUrl}');
      throw const _ChatApiException('No hay conexión con Call a Vet en este momento.');
    } finally {
      _aiChatLog('runAiTurn closing HttpClient');
      client.close(force: true);
    }
  }

  List<Map<String, String>> _historyForApi() {
    final history = _messages
        .where((message) => message.includeInHistory)
        .map(
          (message) => {
            'role': message.isUser ? 'user' : 'assistant',
            'content': message.text,
          },
        )
        .toList(growable: false);
    _aiChatLog('historyForApi prepared count=${history.length} roles=${history.map((message) => message['role']).join(',')}');
    return history;
  }

  void _sendQuickReply(String service) {
    _aiChatLog('quickReply selected service=$service isSending=$_isSending');
    final text = switch (service) {
      'video' => 'Quiero una videollamada ahora con un veterinario.',
      'scheduled_video' => 'Quiero agendar una videollamada con un veterinario.',
      _ => 'Quiero continuar por chat con un veterinario.',
    };
    _sendUserMessage(text);
  }

  String? _uuidOrNull(String value) {
    final trimmed = value.trim();
    return _uuidPattern.hasMatch(trimmed) ? trimmed : null;
  }

  String _friendlyError(Object error) {
    _aiChatLog('friendlyError mapping ${error.runtimeType}');
    if (error is _ChatApiException) return error.message;
    return 'No pude conectar con el asistente ahora mismo. Inténtalo de nuevo.';
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        _aiChatLog('scrollToBottom skipped: no scroll clients yet');
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final thread = _buildThread(context);
    if (widget.embedded) return thread;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF161616), Color(0xFF050505)],
          ),
        ),
        child: SafeArea(
          child: thread,
        ),
      ),
    );
  }

  Widget _buildThread(BuildContext context) {
    return Column(
      children: [
        if (!widget.embedded) _ChatHeader(onBack: () => context.go('/home')),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: EdgeInsets.fromLTRB(widget.embedded ? 0 : 22, widget.embedded ? 10 : 18, widget.embedded ? 0 : 22, 20),
            itemCount: _messages.length + (_isSending ? 1 : 0),
            itemBuilder: (context, index) {
              if (_isSending && index == _messages.length) {
                return const _TypingBubble();
              }
              final message = _messages[index];
              return _MessageBubble(
                message: message,
                embedded: widget.embedded,
                sending: _isSending,
                onQuickReply: _sendQuickReply,
              );
            },
          ),
        ),
        _ChatComposer(
          controller: _inputCtrl,
          focusNode: _focusNode,
          sending: _isSending,
          embedded: widget.embedded,
          includeBottomInset: !widget.embedded,
          onSend: _sendComposerMessage,
        ),
      ],
    );
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 18, 10),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 19),
          ),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  'Call a Vet AI',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    height: 1.1,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  'asistencia veterinaria',
                  style: TextStyle(
                    color: Color(0xFF8F8F8F),
                    fontSize: 11,
                    fontWeight: FontWeight.w300,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.embedded,
    required this.sending,
    required this.onQuickReply,
  });

  final _ChatMessage message;
  final bool embedded;
  final bool sending;
  final ValueChanged<String> onQuickReply;

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final bubbleColor = isUser ? Colors.white : Colors.white.withValues(alpha: 0.07);
    final textColor = isUser ? Colors.black : Colors.white;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * (isUser ? (embedded ? 0.90 : 0.78) : (embedded ? 0.96 : 0.86)),
          ),
          child: Column(
            crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(22),
                    topRight: const Radius.circular(22),
                    bottomLeft: Radius.circular(isUser ? 22 : 6),
                    bottomRight: Radius.circular(isUser ? 6 : 22),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                  child: Text(
                    message.text,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                      height: 1.25,
                    ),
                  ),
                ),
              ),
              if (!isUser && message.result != null) ...[
                const SizedBox(height: 8),
                _HandoffPanel(
                  result: message.result!,
                  sending: sending,
                  onQuickReply: onQuickReply,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _HandoffPanel extends StatelessWidget {
  const _HandoffPanel({
    required this.result,
    required this.sending,
    required this.onQuickReply,
  });

  final _AiChatTurnResult result;
  final bool sending;
  final ValueChanged<String> onQuickReply;

  @override
  Widget build(BuildContext context) {
    final payload = result.payload;
    final recommended = payload.recommendedService;
    final services = ['chat', 'video', 'scheduled_video'];

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatusPill(text: _urgencyLabel(payload.urgency), urgent: payload.safetyEscalation),
                if (result.specialtyName != null) _StatusPill(text: result.specialtyName!),
                if (result.vetName != null) _StatusPill(text: result.vetName!),
                if (result.remaining != null) _StatusPill(text: '${result.remaining} disponibles'),
              ],
            ),
            if (recommended != null || payload.actionLabel != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: services.map((service) {
                  final selected = service == recommended;
                  return _ServiceButton(
                    label: selected && payload.actionLabel != null ? payload.actionLabel! : _serviceLabel(service),
                    selected: selected,
                    enabled: !sending,
                    onTap: () => onQuickReply(service),
                  );
                }).toList(growable: false),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _urgencyLabel(String urgency) {
    return switch (urgency) {
      'emergency' => 'emergencia',
      'urgent' => 'urgente',
      _ => 'rutina',
    };
  }

  String _serviceLabel(String service) {
    return switch (service) {
      'video' => 'video ahora',
      'scheduled_video' => 'agendar video',
      _ => 'chat',
    };
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.text, this.urgent = false});

  final String text;
  final bool urgent;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: urgent ? const Color(0xFFFFD6CF).withValues(alpha: 0.16) : Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          text,
          style: TextStyle(
            color: urgent ? const Color(0xFFFFD6CF) : Colors.white.withValues(alpha: 0.78),
            fontSize: 11,
            fontWeight: FontWeight.w400,
            height: 1,
          ),
        ),
      ),
    );
  }
}

class _ServiceButton extends StatelessWidget {
  const _ServiceButton({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 160),
        opacity: enabled ? 1 : 0.45,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(30),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.black : Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(22),
        ),
        child: const SizedBox(
          width: 32,
          child: LinearProgressIndicator(
            minHeight: 2,
            color: Colors.white,
            backgroundColor: Color(0xFF3A3A3A),
          ),
        ),
      ),
    );
  }
}

class _ChatComposer extends StatelessWidget {
  const _ChatComposer({
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.embedded,
    required this.includeBottomInset,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final bool embedded;
  final bool includeBottomInset;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final bottomInset = includeBottomInset ? MediaQuery.paddingOf(context).bottom : 0.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(embedded ? 0 : 18, 8, embedded ? 0 : 18, 14 + bottomInset),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 46, maxHeight: 150),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Padding(
            padding: const EdgeInsets.only(left: 18, right: 6, top: 3, bottom: 3),
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
                    textInputAction: TextInputAction.send,
                    minLines: 1,
                    maxLines: 6,
                    onSubmitted: (_) => onSend(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      height: 1.25,
                    ),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: 'escribir mensaje...',
                      hintStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.32),
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        height: 1.25,
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
                      disabledBackgroundColor: Colors.white.withValues(alpha: 0.25),
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
    );
  }
}

enum _ChatRole { user, assistant }

class _ChatMessage {
  const _ChatMessage({
    required this.role,
    required this.text,
    this.result,
    this.includeInHistory = true,
  });

  factory _ChatMessage.user(String text) {
    return _ChatMessage(role: _ChatRole.user, text: text);
  }

  factory _ChatMessage.assistant(
    String text, {
    _AiChatTurnResult? result,
    bool includeInHistory = true,
  }) {
    return _ChatMessage(
      role: _ChatRole.assistant,
      text: text,
      result: result,
      includeInHistory: includeInHistory,
    );
  }

  final _ChatRole role;
  final String text;
  final _AiChatTurnResult? result;
  final bool includeInHistory;

  bool get isUser => role == _ChatRole.user;
}

class _AiChatTurnResult {
  const _AiChatTurnResult({
    required this.payload,
    this.specialtyName,
    this.vetName,
    this.remaining,
  });

  factory _AiChatTurnResult.fromJson(Map<String, dynamic> json) {
    final payload = _AiChatPayload.fromJson(_asMap(json['payload']) ?? <String, dynamic>{});
    String? specialtyName;
    String? vetName;
    int? remaining;
    final toolNames = <String>[];

    for (final item in _asList(json['toolResults']) ?? const []) {
      final tool = _asMap(item);
      final name = tool?['name']?.toString();
      if (name != null) toolNames.add(name);
      final output = _asMap(tool?['output']);
      if (name == 'recommend_specialty') {
        specialtyName = _asMap(output?['specialty'])?['name']?.toString();
      }
      if (name == 'find_vets') {
        final vets = _asList(output?['vets']);
        final firstVet = vets == null || vets.isEmpty ? null : _asMap(vets.first);
        vetName = firstVet?['full_name']?.toString();
      }
      if (name == 'check_service_access') {
        final value = output?['remaining'];
        remaining = value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
      }
    }

    _aiChatLog(
      'AiChatTurnResult.fromJson payload={urgency:${payload.urgency}, recommendedService:${payload.recommendedService}, '
      'actionLabel:${payload.actionLabel}, safetyEscalation:${payload.safetyEscalation}, messageLength:${payload.message.length}} '
      'toolNames=${toolNames.join(',')} specialty=$specialtyName vet=$vetName remaining=$remaining',
    );

    return _AiChatTurnResult(
      payload: payload,
      specialtyName: specialtyName,
      vetName: vetName,
      remaining: remaining,
    );
  }

  final _AiChatPayload payload;
  final String? specialtyName;
  final String? vetName;
  final int? remaining;
}

class _AiChatPayload {
  const _AiChatPayload({
    required this.message,
    required this.urgency,
    required this.recommendedService,
    required this.actionLabel,
    required this.safetyEscalation,
  });

  factory _AiChatPayload.fromJson(Map<String, dynamic> json) {
    return _AiChatPayload(
      message: json['message']?.toString() ?? 'Te ayudo a encontrar el veterinario adecuado.',
      urgency: json['urgency']?.toString() ?? 'routine',
      recommendedService: json['recommendedService']?.toString(),
      actionLabel: json['actionLabel']?.toString(),
      safetyEscalation: json['safetyEscalation'] == true,
    );
  }

  final String message;
  final String urgency;
  final String? recommendedService;
  final String? actionLabel;
  final bool safetyEscalation;
}

class _ChatApiException implements Exception {
  const _ChatApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

Map<String, dynamic>? _asMap(Object? value) {
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

List<Object?>? _asList(Object? value) {
  return value is List ? value : null;
}

String _errorMessage(Map<String, dynamic> data, int statusCode) {
  final message = data['message'] ?? data['error'];
  if (message is List && message.isNotEmpty) return message.first.toString();
  if (message != null) return message.toString();
  return 'El asistente respondió con error $statusCode.';
}
