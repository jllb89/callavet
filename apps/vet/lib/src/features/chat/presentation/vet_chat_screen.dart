import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/environment.dart';

class VetChatScreen extends StatefulWidget {
  const VetChatScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  State<VetChatScreen> createState() => _VetChatScreenState();
}

class _VetChatScreenState extends State<VetChatScreen> {
  final TextEditingController _composerController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  RealtimeChannel? _messagesChannel;
  Timer? _refreshDebounce;
  late Future<List<_VetChatMessage>> _messagesFuture;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _messagesFuture = _loadMessages();
    _startMessagesRealtime();
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    final channel = _messagesChannel;
    if (channel != null) {
      Supabase.instance.client.removeChannel(channel);
    }
    _composerController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<List<_VetChatMessage>> _loadMessages() async {
    final response = await _getGatewayJson(
      '/sessions/${Uri.encodeComponent(widget.sessionId)}/messages?limit=100&sort=created_at.asc',
    );
    final messages = _asList(response['items'])
            ?.map(_asMap)
            .whereType<Map<String, dynamic>>()
            .map(_VetChatMessage.fromJson)
            .toList() ??
        const <_VetChatMessage>[];
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    return messages;
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
          callback: (_) => _scheduleRefresh(),
        )
        .subscribe();
    _messagesChannel = channel;
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce =
        Timer(const Duration(milliseconds: 450), _refreshMessages);
  }

  void _refreshMessages() {
    if (!mounted) return;
    setState(() {
      _messagesFuture = _loadMessages();
    });
  }

  Future<void> _sendMessage() async {
    final text = _composerController.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _postGatewayJson(
          '/sessions/${Uri.encodeComponent(widget.sessionId)}/messages', {
        'role': 'vet',
        'content': text,
      });
      _composerController.clear();
      _refreshMessages();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo enviar: $error')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
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
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
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
          child: Column(
            children: [
              _ChatTopBar(
                  sessionId: widget.sessionId,
                  onBack: () => context.canPop()
                      ? context.pop()
                      : context.go('/dashboard')),
              Expanded(
                child: FutureBuilder<List<_VetChatMessage>>(
                  future: _messagesFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(
                          child:
                              CircularProgressIndicator(color: Colors.white));
                    }
                    if (snapshot.hasError) {
                      return _ChatStatusView(
                        icon: Icons.chat_bubble_outline_rounded,
                        title: 'No pude cargar el chat',
                        message: snapshot.error.toString(),
                        onRetry: _refreshMessages,
                      );
                    }
                    final messages = snapshot.data ?? const <_VetChatMessage>[];
                    if (messages.isEmpty) {
                      return const _ChatStatusView(
                        icon: Icons.forum_outlined,
                        title: 'Chat listo',
                        message: 'Aún no hay mensajes en esta consulta.',
                      );
                    }
                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
                      itemCount: messages.length,
                      itemBuilder: (context, index) =>
                          _ChatBubble(message: messages[index]),
                    );
                  },
                ),
              ),
              _ChatComposer(
                controller: _composerController,
                sending: _sending,
                onSend: _sendMessage,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatTopBar extends StatelessWidget {
  const _ChatTopBar({required this.sessionId, required this.onBack});

  final String sessionId;
  final VoidCallback onBack;

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
                  'sesión $shortId',
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
        ],
      ),
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
            Text(
              message.content,
              style: TextStyle(
                color: isVet ? Colors.black : Colors.white,
                fontSize: 14,
                fontFamily: 'ABC Diatype',
                height: 1.28,
              ),
            ),
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

class _ChatComposer extends StatelessWidget {
  const _ChatComposer(
      {required this.controller, required this.sending, required this.onSend});

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              style: const TextStyle(
                  color: Colors.white, fontFamily: 'ABC Diatype', fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Escribe una respuesta...',
                hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.42),
                    fontFamily: 'ABC Diatype'),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.07),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: sending ? null : onSend,
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: sending
                    ? Colors.white.withValues(alpha: 0.38)
                    : Colors.white,
                shape: BoxShape.circle,
              ),
              child: sending
                  ? const Padding(
                      padding: EdgeInsets.all(13),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.black),
                    )
                  : const Icon(Icons.send_rounded,
                      color: Colors.black, size: 19),
            ),
          ),
        ],
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
      required this.role,
      required this.content,
      required this.createdAt});

  factory _VetChatMessage.fromJson(Map<String, dynamic> json) {
    return _VetChatMessage(
      id: json['id']?.toString() ?? '',
      role: json['role']?.toString().toLowerCase() ?? 'user',
      content: json['content']?.toString() ?? '',
      createdAt: _parseDateTime(json['created_at']),
    );
  }

  final String id;
  final String role;
  final String content;
  final DateTime? createdAt;

  String get label {
    final who = role == 'vet'
        ? 'tú'
        : role == 'ai'
            ? 'asistente'
            : 'tutor';
    if (createdAt == null) return who;
    final hour = createdAt!.hour.toString().padLeft(2, '0');
    final minute = createdAt!.minute.toString().padLeft(2, '0');
    return '$who · $hour:$minute';
  }
}

Map<String, dynamic>? _asMap(Object? value) {
  return value is Map
      ? value.map((key, val) => MapEntry(key.toString(), val))
      : null;
}

List<dynamic>? _asList(Object? value) => value is List ? value : null;

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
