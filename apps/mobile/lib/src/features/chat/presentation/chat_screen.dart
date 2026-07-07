import 'dart:math' as math;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/environment.dart';

const _aiChatDryRun = bool.fromEnvironment('CAV_AI_CHAT_DRY_RUN');
const _chatPlanOrder = [
  'starter',
  'plus',
  'cuadra',
  'cuadra-15',
  'pro-entrenador',
  'rancho-trabajo',
];
const _noUpgradePlanAvailableMessage =
    'No encontré un plan superior que libere disponibilidad para esta consulta.';
int _chatMessageSequence = 0;
final _sessionMessageCache = <String, List<_ChatMessage>>{};

String _nextChatMessageId() {
  _chatMessageSequence += 1;
  return '${DateTime.now().microsecondsSinceEpoch}-$_chatMessageSequence';
}

void _aiChatLog(String message) {
  debugPrint('[AIChat][Mobile] $message');
}

void _surveyChatLog(String message) {
  debugPrint('[ConsultSurvey][Chat] $message');
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
    this.homeDisplayName,
    this.initialAssistantMessage,
    this.initialRejoinVideo = false,
    this.initialSurvey = false,
  });

  final String sessionId;
  final String? initialMessage;
  final String? homeDisplayName;
  final String? initialAssistantMessage;
  final bool initialRejoinVideo;
  final bool initialSurvey;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputCtrl = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  final _messages = <_ChatMessage>[];

  late final String _conversationId;
  RealtimeChannel? _consultMessagesChannel;
  RealtimeChannel? _consultSessionChannel;
  RealtimeChannel? _consultRoomChannel;
  Timer? _consultRefreshDebounce;
  Timer? _typingDebounce;
  Timer? _vetTypingClearTimer;
  Timer? _surveyReturnHomeTimer;
  bool _isSending = false;
  bool _isReturningHome = false;
  bool _surveyLoading = false;
  bool _consultLoading = false;
  bool _consultClosed = false;
  bool _endingConsult = false;
  bool _vetOnline = false;
  bool _vetTyping = false;
  _ActiveSurveyFeedback? _activeSurveyFeedback;

  static const _surveyReturnHomeDelay = Duration(seconds: 5);
  static const _returnHomeFadeDuration = Duration(milliseconds: 260);

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
      'initialMessageLength=${widget.initialMessage?.trim().length ?? 0} '
      'homeDisplayNamePresent=${widget.homeDisplayName?.trim().isNotEmpty == true} '
      'initialAssistantMessagePresent=${widget.initialAssistantMessage?.trim().isNotEmpty == true} '
      'initialRejoinVideo=${widget.initialRejoinVideo} '
      'initialSurvey=${widget.initialSurvey} '
      'apiBaseUrl=${Environment.apiBaseUrl} dryRun=$_aiChatDryRun',
    );
    final initialMessage = widget.initialMessage?.trim();
    final hasInitialMessage =
        initialMessage != null && initialMessage.isNotEmpty;
    final initialAssistantMessage = widget.initialAssistantMessage?.trim();
    final hasInitialAssistantMessage =
        initialAssistantMessage != null && initialAssistantMessage.isNotEmpty;
    final cachedSessionId = _uuidOrNull(widget.sessionId);
    if (_isConsultChatRoute && cachedSessionId != null) {
      _inputCtrl.addListener(_handleComposerChanged);
      unawaited(_loadConsultMessages());
      _startConsultRealtime(cachedSessionId);
      _startConsultRoomSignals(cachedSessionId);
    }
    final cachedMessages = cachedSessionId == null || _isConsultChatRoute
        ? null
        : _sessionMessageCache[cachedSessionId];
    if (cachedMessages != null && cachedMessages.isNotEmpty) {
      _messages.addAll(cachedMessages);
      _aiChatLog(
          'restored cached session chat sessionId=$cachedSessionId messages=${cachedMessages.length}');
    }
    if (hasInitialAssistantMessage) {
      _aiChatLog(
          'initial assistant post-call message inserted length=${initialAssistantMessage.length}');
      _messages.add(_ChatMessage.assistant(
        initialAssistantMessage,
        includeInHistory: false,
        rejoinSessionId: widget.initialRejoinVideo ? widget.sessionId : null,
      ));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (hasInitialMessage) {
        _aiChatLog(
            'postFrame auto-sending initial message preview="${_preview(initialMessage)}"');
        _sendUserMessage(initialMessage);
      } else if (widget.initialSurvey) {
        _surveyChatLog('postFrame starting consult survey prompt');
        unawaited(_startSurveyPrompt());
      } else {
        _aiChatLog('postFrame no initial message; focusing composer');
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    final sessionId = _uuidOrNull(widget.sessionId);
    if (sessionId != null && !_isConsultChatRoute) {
      _cacheSessionMessages(sessionId);
    }
    _consultRefreshDebounce?.cancel();
    final messagesChannel = _consultMessagesChannel;
    if (messagesChannel != null) {
      Supabase.instance.client.removeChannel(messagesChannel);
    }
    final sessionChannel = _consultSessionChannel;
    if (sessionChannel != null) {
      Supabase.instance.client.removeChannel(sessionChannel);
    }
    final roomChannel = _consultRoomChannel;
    if (roomChannel != null) {
      unawaited(roomChannel.untrack());
      Supabase.instance.client.removeChannel(roomChannel);
    }
    _typingDebounce?.cancel();
    _vetTypingClearTimer?.cancel();
    _aiChatLog(
        'dispose conversationId=$_conversationId totalMessages=${_messages.length}');
    _inputCtrl.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    _surveyReturnHomeTimer?.cancel();
    super.dispose();
  }

  void _scheduleSurveyReturnHome() {
    _surveyReturnHomeTimer?.cancel();
    _surveyChatLog(
        'return home scheduled after ${_surveyReturnHomeDelay.inSeconds}s');
    _surveyReturnHomeTimer = Timer(_surveyReturnHomeDelay, () {
      if (!mounted) return;
      _surveyChatLog('returning home after survey completion or skip');
      unawaited(_returnHome());
    });
  }

  Future<void> _returnHome() async {
    if (_isReturningHome) return;
    _surveyReturnHomeTimer?.cancel();
    _focusNode.unfocus();
    setState(() => _isReturningHome = true);
    await Future<void>.delayed(_returnHomeFadeDuration);
    if (!mounted) return;
    context.go('/home');
  }

  String get _homeDisplayName {
    final trimmed = widget.homeDisplayName?.trim();
    return trimmed == null || trimmed.isEmpty ? 'Jorge' : trimmed;
  }

  bool get _showsHomeIntro => widget.sessionId == 'ai';

  bool get _isConsultChatRoute {
    final sessionId = _uuidOrNull(widget.sessionId);
    final hasAssistantMessage =
        widget.initialAssistantMessage?.trim().isNotEmpty == true;
    return sessionId != null &&
        !widget.initialSurvey &&
        !widget.initialRejoinVideo &&
        !hasAssistantMessage;
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
    _aiChatLog(
        'composer send accepted length=${text.length} preview="${_preview(text)}"');
    _inputCtrl.clear();
    final activeSurveyFeedback = _activeSurveyFeedback;
    if (activeSurveyFeedback != null) {
      _submitSurveyFeedback(activeSurveyFeedback, text);
      return;
    }
    if (_isConsultChatRoute) {
      unawaited(_sendConsultMessage(text));
      return;
    }
    _sendUserMessage(text);
  }

  Future<void> _loadConsultMessages() async {
    final sessionId = _uuidOrNull(widget.sessionId);
    if (sessionId == null) return;
    _aiChatLog('consult load messages sessionId=$sessionId');
    if (mounted) setState(() => _consultLoading = true);
    try {
      final response = await _getGatewayJson(
        '/sessions/${Uri.encodeComponent(sessionId)}/messages?limit=100&sort=stream_order.asc',
      );
      final messages = (_asList(response['items']) ?? const [])
          .map(_asMap)
          .whereType<Map<String, dynamic>>()
          .map(_ChatMessage.consultFromJson)
          .toList(growable: false);
      final receipts = _asList(response['receipts']) ?? const [];
      final session = _asMap(response['session']);
      final status = session?['status']?.toString().toLowerCase();
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(_messagesWithReceipts(messages, receipts));
        _consultClosed = _isClosedConsultStatus(status);
      });
      _markVisibleConsultMessagesRead();
      if (_consultClosed) unawaited(_startSurveyPrompt());
      _scrollToBottom();
    } catch (error) {
      _aiChatLog('consult load failed: ${error.runtimeType} $error');
      if (!mounted) return;
      setState(() {
        if (_messages.isEmpty) {
          _messages.add(_ChatMessage.assistant(_friendlyError(error),
              includeInHistory: false));
        }
      });
    } finally {
      if (mounted) setState(() => _consultLoading = false);
    }
  }

  void _startConsultRealtime(String sessionId) {
    final messagesChannel =
        Supabase.instance.client.channel('owner-chat-messages:$sessionId');
    messagesChannel
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'session_id',
            value: sessionId,
          ),
          callback: (payload) {
            final record = payload.newRecord.isNotEmpty
                ? payload.newRecord
                : payload.oldRecord;
            final message = _ChatMessage.consultFromJson(record);
            if (message.id.isEmpty) {
              _scheduleConsultRefresh();
              return;
            }
            _upsertConsultMessage(message);
          },
        )
        .subscribe();
    _consultMessagesChannel = messagesChannel;

    final sessionChannel =
        Supabase.instance.client.channel('owner-chat-session:$sessionId');
    sessionChannel
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'chat_sessions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: sessionId,
          ),
          callback: (payload) {
            final status =
                payload.newRecord['status']?.toString().toLowerCase();
            if (_isClosedConsultStatus(status)) {
              if (mounted) setState(() => _consultClosed = true);
              unawaited(_startSurveyPrompt());
            }
          },
        )
        .subscribe();
    _consultSessionChannel = sessionChannel;
  }

  void _startConsultRoomSignals(String sessionId) {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;
    final channel = Supabase.instance.client.channel(
      'consult-room:$sessionId',
      opts: RealtimeChannelConfig(private: true, key: userId),
    );
    channel
        .onBroadcast(
          event: 'typing',
          callback: (payload) {
            if (payload['role']?.toString() != 'vet') return;
            final typing = payload['typing'] == true;
            if (!mounted) return;
            setState(() => _vetTyping = typing);
            _vetTypingClearTimer?.cancel();
            if (typing) {
              _vetTypingClearTimer = Timer(const Duration(seconds: 3), () {
                if (mounted) setState(() => _vetTyping = false);
              });
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
        .onBroadcast(
          event: 'messages',
          callback: (payload) {
            final record = _asMap(payload['message']);
            if (record == null) {
              _scheduleConsultRefresh();
              return;
            }
            final message = _ChatMessage.consultFromJson(record);
            if (message.id.isEmpty) {
              _scheduleConsultRefresh();
              return;
            }
            _upsertConsultMessage(message);
          },
        )
        .onPresenceSync((_) => _syncVetPresence(channel))
        .subscribe((status, [_]) {
      if (status == RealtimeSubscribeStatus.subscribed) {
        unawaited(channel.track({
          'role': 'user',
          'userId': userId,
          'onlineAt': DateTime.now().toIso8601String(),
        }));
      }
    });
    _consultRoomChannel = channel;
  }

  void _syncVetPresence(RealtimeChannel channel) {
    final online = channel.presenceState().any((state) => state.presences.any(
          (presence) => presence.payload['role']?.toString() == 'vet',
        ));
    if (mounted) setState(() => _vetOnline = online);
  }

  void _handleComposerChanged() {
    if (!_isConsultChatRoute || _consultClosed || _consultRoomChannel == null) {
      return;
    }
    _typingDebounce?.cancel();
    final isTyping = _inputCtrl.text.trim().isNotEmpty;
    _typingDebounce = Timer(const Duration(milliseconds: 300), () {
      final channel = _consultRoomChannel;
      if (channel == null) return;
      unawaited(channel.sendBroadcastMessage(
        event: 'typing',
        payload: {
          'role': 'user',
          'typing': isTyping,
          'at': DateTime.now().toIso8601String(),
        },
      ));
    });
  }

  void _scheduleConsultRefresh() {
    _consultRefreshDebounce?.cancel();
    _consultRefreshDebounce =
        Timer(const Duration(milliseconds: 350), _refreshConsultMessages);
  }

  void _refreshConsultMessages() {
    if (!mounted) return;
    unawaited(_loadConsultMessages());
  }

  void _upsertConsultMessage(_ChatMessage message) {
    if (!mounted) return;
    setState(() {
      final index =
          _messages.indexWhere((existing) => existing.id == message.id);
      if (index >= 0) {
        _messages[index] = message.withReceiptFrom(_messages[index]);
      } else {
        _messages.add(message);
      }
      _messages.sort(_compareConsultMessages);
    });
    if (!message.isUser) _markVisibleConsultMessagesRead();
    _scrollToBottom();
  }

  int _compareConsultMessages(_ChatMessage a, _ChatMessage b) {
    final aOrder = a.streamOrder;
    final bOrder = b.streamOrder;
    if (aOrder != null && bOrder != null && aOrder != bOrder) {
      return aOrder.compareTo(bOrder);
    }
    return a.id.compareTo(b.id);
  }

  List<_ChatMessage> _messagesWithReceipts(
    List<_ChatMessage> messages,
    List<dynamic> receipts,
  ) {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    return messages.map((message) {
      if (!message.isUser) return message;
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
      final index = _messages.indexWhere((message) => message.id == messageId);
      if (index < 0 || !_messages[index].isUser) return;
      _messages[index] = _messages[index].copyWith(
        deliveredByOther: receipt['delivered_at'] != null,
        readByOther: receipt['read_at'] != null,
      );
    });
  }

  void _markVisibleConsultMessagesRead() {
    final sessionId = _uuidOrNull(widget.sessionId);
    if (sessionId == null) return;
    final lastStreamOrder = _messages
        .where((message) => !message.isUser)
        .map((message) => message.streamOrder ?? 0)
        .fold<int>(0, (max, value) => value > max ? value : max);
    if (lastStreamOrder <= 0) return;
    unawaited(_postGatewayJson(
      '/sessions/${Uri.encodeComponent(sessionId)}/messages/read',
      {'lastStreamOrder': lastStreamOrder},
    ));
  }

  Future<void> _sendConsultMessage(String text) async {
    final sessionId = _uuidOrNull(widget.sessionId);
    if (sessionId == null || _isSending) return;
    if (_consultClosed) {
      setState(() {
        _messages.add(_ChatMessage.assistant(
          'Esta consulta ya terminó. Puedes completar la encuesta o volver al inicio.',
          includeInHistory: false,
        ));
      });
      _scrollToBottom();
      return;
    }
    final clientKey =
        'owner-${DateTime.now().microsecondsSinceEpoch}-${_nextChatMessageId()}';
    setState(() {
      _messages.add(_ChatMessage.user(text, includeInHistory: false));
      _isSending = true;
    });
    _scrollToBottom();

    try {
      await _postGatewayJson(
        '/sessions/${Uri.encodeComponent(sessionId)}/messages',
        {
          'content': text,
          'clientKey': clientKey,
        },
      );
      await _loadConsultMessages();
    } catch (error) {
      _aiChatLog('consult send failed: ${error.runtimeType} $error');
      if (!mounted) return;
      setState(() => _messages.add(_ChatMessage.assistant(_friendlyError(error),
          includeInHistory: false)));
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _endConsultFromOwner() async {
    final sessionId = _uuidOrNull(widget.sessionId);
    if (sessionId == null || _endingConsult || _consultClosed) return;
    setState(() => _endingConsult = true);
    try {
      await _postGatewayJson('/sessions/end', {'sessionId': sessionId});
      if (!mounted) return;
      setState(() => _consultClosed = true);
      unawaited(_startSurveyPrompt());
    } catch (error) {
      _aiChatLog('owner consult end failed: ${error.runtimeType} $error');
      if (!mounted) return;
      setState(() => _messages.add(_ChatMessage.assistant(_friendlyError(error),
          includeInHistory: false)));
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _endingConsult = false);
    }
  }

  bool _isClosedConsultStatus(String? status) {
    return status == 'completed' || status == 'canceled' || status == 'no_show';
  }

  Future<void> _startSurveyPrompt() async {
    final sessionId = _uuidOrNull(widget.sessionId);
    if (sessionId == null || _surveyLoading) return;
    if (_messages.any((message) => message.surveyAction != null)) {
      _surveyChatLog('prompt skipped: survey action already visible');
      return;
    }
    setState(() => _surveyLoading = true);
    try {
      final response = await _getGatewayJson(
          '/sessions/${Uri.encodeComponent(sessionId)}/survey');
      final surveyResponse = _SurveyResponse.fromJson(response);
      _surveyChatLog(
        'get response eligible=${surveyResponse.eligible} status=${surveyResponse.survey?.status} reason=${surveyResponse.reason}',
      );
      if (!mounted ||
          !surveyResponse.eligible ||
          surveyResponse.survey == null) {
        return;
      }
      _continueSurvey(surveyResponse.survey!);
    } catch (error) {
      _surveyChatLog('get failed: ${error.runtimeType} $error');
    } finally {
      if (mounted) setState(() => _surveyLoading = false);
    }
  }

  void _continueSurvey(_ConsultSurvey survey) {
    if (!mounted) return;
    if (survey.status == 'completed' || survey.status == 'dismissed') return;
    final hasPrompt = _messages.any((message) =>
        message.surveyAction?.surveyId == survey.id &&
        message.surveyAction?.step == _SurveyStep.prompt);
    if ((survey.status == 'pending' || survey.status == 'deferred') &&
        !hasPrompt) {
      setState(() {
        _messages.add(_ChatMessage.assistant(
          '¿Quieres calificar esta consulta ahora?',
          includeInHistory: false,
          surveyAction: _SurveyAction.prompt(survey),
        ));
      });
      _scrollToBottom();
      return;
    }
    if (survey.vetAssistanceScore == null) {
      _showSurveyVetScore(survey);
      return;
    }
    if (survey.appServiceScore == null) {
      _showSurveyAppScore(survey);
      return;
    }
    if (survey.status != 'completed') {
      _showSurveyFeedback(survey);
    }
  }

  Future<void> _handleSurveyAction(_SurveyActionChoice choice) async {
    switch (choice.type) {
      case _SurveyActionType.startNow:
      case _SurveyActionType.later:
      case _SurveyActionType.dismiss:
        await _answerSurveyPrompt(choice);
        break;
      case _SurveyActionType.vetScore:
        await _saveSurveyScore(choice, vetScore: choice.score);
        break;
      case _SurveyActionType.appScore:
        await _saveSurveyScore(choice, appScore: choice.score);
        break;
      case _SurveyActionType.skipFeedback:
        final active = _activeSurveyFeedback;
        if (active != null) await _submitSurveyFeedback(active, null);
        break;
    }
  }

  Future<void> _answerSurveyPrompt(_SurveyActionChoice choice) async {
    final answer = switch (choice.type) {
      _SurveyActionType.startNow => 'now',
      _SurveyActionType.later => 'later',
      _ => 'dismiss',
    };
    _surveyChatLog('prompt answer surveyId=${choice.survey.id} answer=$answer');
    setState(() => _isSending = true);
    try {
      final response = await _postGatewayJson(
        '/sessions/${Uri.encodeComponent(choice.survey.sessionId)}/survey/prompt-response',
        {'answer': answer},
      );
      final survey = _SurveyResponse.fromJson(response).survey;
      if (!mounted || survey == null) return;
      if (answer == 'now') {
        _showSurveyVetScore(survey);
      } else {
        setState(() {
          _messages.add(_ChatMessage.assistant(
            answer == 'later'
                ? 'Claro, te lo preguntaremos más tarde.'
                : 'Listo, no volveremos a pedir esta encuesta para esta consulta.',
            includeInHistory: false,
          ));
        });
        _scheduleSurveyReturnHome();
      }
    } catch (error) {
      _surveyChatLog('prompt answer failed: ${error.runtimeType} $error');
      if (!mounted) return;
      setState(() => _messages.add(_ChatMessage.assistant(_friendlyError(error),
          includeInHistory: false)));
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
        _scrollToBottom();
      }
    }
  }

  Future<void> _saveSurveyScore(
    _SurveyActionChoice choice, {
    int? vetScore,
    int? appScore,
  }) async {
    final label = choice.label;
    _surveyChatLog(
      'score selected surveyId=${choice.survey.id} step=${choice.type} score=${choice.score}',
    );
    setState(() {
      _messages.add(_ChatMessage.user(label, includeInHistory: false));
      _isSending = true;
    });
    try {
      final response = await _patchGatewayJson(
        '/sessions/${Uri.encodeComponent(choice.survey.sessionId)}/survey',
        {
          if (vetScore != null) 'vetAssistanceScore': vetScore,
          if (appScore != null) 'appServiceScore': appScore,
        },
      );
      final survey = _SurveyResponse.fromJson(response).survey;
      if (!mounted || survey == null) return;
      if (appScore != null) {
        _showSurveyFeedback(survey);
      } else {
        _showSurveyAppScore(survey);
      }
    } catch (error) {
      _surveyChatLog('score save failed: ${error.runtimeType} $error');
      if (!mounted) return;
      setState(() => _messages.add(_ChatMessage.assistant(_friendlyError(error),
          includeInHistory: false)));
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
        _scrollToBottom();
      }
    }
  }

  void _showSurveyVetScore(_ConsultSurvey survey) {
    if (_messages.any((message) =>
        message.surveyAction?.surveyId == survey.id &&
        message.surveyAction?.step == _SurveyStep.vetScore)) {
      return;
    }
    setState(() {
      _messages.add(_ChatMessage.assistant(
        '¿Cómo calificas la asistencia proporcionada por parte del veterinario?',
        includeInHistory: false,
        surveyAction: _SurveyAction.score(survey, _SurveyStep.vetScore),
      ));
    });
    _scrollToBottom();
  }

  void _showSurveyAppScore(_ConsultSurvey survey) {
    if (_messages.any((message) =>
        message.surveyAction?.surveyId == survey.id &&
        message.surveyAction?.step == _SurveyStep.appScore)) {
      return;
    }
    setState(() {
      _messages.add(_ChatMessage.assistant(
        '¿Cómo calificas el funcionamiento general de la aplicación?',
        includeInHistory: false,
        surveyAction: _SurveyAction.score(survey, _SurveyStep.appScore),
      ));
    });
    _scrollToBottom();
  }

  void _showSurveyFeedback(_ConsultSurvey survey) {
    if (_messages.any((message) =>
        message.surveyAction?.surveyId == survey.id &&
        message.surveyAction?.step == _SurveyStep.feedback)) {
      return;
    }
    setState(() {
      _activeSurveyFeedback = _ActiveSurveyFeedback(survey: survey);
      _messages.add(_ChatMessage.assistant(
        '¿Hay algo más que quieras contarnos?',
        includeInHistory: false,
        surveyAction: _SurveyAction.feedback(survey),
      ));
    });
    _focusNode.requestFocus();
    _scrollToBottom();
  }

  Future<void> _submitSurveyFeedback(
      _ActiveSurveyFeedback active, String? feedback) async {
    final trimmed = feedback?.trim();
    _surveyChatLog(
        'feedback submit surveyId=${active.survey.id} hasFeedback=${trimmed?.isNotEmpty == true}');
    setState(() {
      if (trimmed != null && trimmed.isNotEmpty) {
        _messages.add(_ChatMessage.user(trimmed, includeInHistory: false));
      }
      _isSending = true;
    });
    try {
      await _patchGatewayJson(
        '/sessions/${Uri.encodeComponent(active.survey.sessionId)}/survey',
        {
          'status': 'completed',
          if (trimmed != null && trimmed.isNotEmpty) 'openFeedback': trimmed,
        },
      );
      if (!mounted) return;
      setState(() {
        _activeSurveyFeedback = null;
        _messages.add(_ChatMessage.assistant(
          'Gracias por ayudarnos a mejorar Call a Vet.',
          includeInHistory: false,
        ));
      });
      _scheduleSurveyReturnHome();
    } catch (error) {
      _surveyChatLog('feedback submit failed: ${error.runtimeType} $error');
      if (!mounted) return;
      setState(() => _messages.add(_ChatMessage.assistant(_friendlyError(error),
          includeInHistory: false)));
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
        _scrollToBottom();
      }
    }
  }

  Future<void> _sendUserMessage(String text) async {
    if (_isSending) {
      _aiChatLog(
          'sendUserMessage ignored while sending preview="${_preview(text)}"');
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
    _aiChatLog(
        'sendUserMessage state updated: user bubble appended isSending=$_isSending');
    _scrollToBottom();

    try {
      final response = await _runAiTurn(text, history);
      _aiChatLog(
          'sendUserMessage raw response keys=${response.keys.join(',')}');
      final result = _AiChatTurnResult.fromJson(response);
      _aiChatLog(
        'sendUserMessage parsed result urgency=${result.payload.urgency} '
        'recommendedService=${result.payload.recommendedService} actionLabel=${result.payload.actionLabel} '
        'specialty=${result.specialtyName} vet=${result.vetName} remaining=${result.remaining}',
      );
      if (!mounted) return;
      setState(() {
        _messages.add(
            _ChatMessage.assistant(result.payload.message, result: result));
        _isSending = false;
      });
      _aiChatLog(
          'sendUserMessage success: assistant bubble appended totalMessages=${_messages.length}');
      _scrollToBottom();
    } catch (error) {
      _aiChatLog('sendUserMessage failed: ${error.runtimeType} $error');
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage.assistant(_friendlyError(error),
            includeInHistory: false));
        _isSending = false;
      });
      _aiChatLog(
          'sendUserMessage error bubble appended totalMessages=${_messages.length}');
      _scrollToBottom();
    }
  }

  Future<Map<String, dynamic>> _runAiTurn(
    String message,
    List<Map<String, dynamic>> history,
  ) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    _aiChatLog(
        'runAiTurn auth snapshot tokenPresent=${token?.isNotEmpty == true} userId=$userId');
    if (token == null || token.isEmpty) {
      _aiChatLog('runAiTurn aborted: missing Supabase access token');
      throw const _ChatApiException(
          'Tu sesión expiró. Vuelve a iniciar sesión.');
    }

    final sessionId = _uuidOrNull(widget.sessionId);
    _aiChatLog(
        'runAiTurn session routing raw=${widget.sessionId} normalized=${sessionId ?? 'none'}');
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
      final request =
          await client.postUrl(uri).timeout(const Duration(seconds: 10));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.add(utf8.encode(jsonEncode(body)));
      _aiChatLog('runAiTurn request sent; awaiting gateway response');

      final response =
          await request.close().timeout(const Duration(seconds: 45));
      final rawBody = await utf8.decoder.bind(response).join();
      final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
      _aiChatLog(
        'runAiTurn response status=${response.statusCode} elapsedMs=$elapsedMs bodyLength=${rawBody.length} '
        'bodyPreview="${_preview(rawBody, max: 500)}"',
      );
      final decoded =
          rawBody.trim().isEmpty ? <String, dynamic>{} : jsonDecode(rawBody);
      final data = _asMap(decoded) ?? <String, dynamic>{};
      _aiChatLog('runAiTurn decoded response mapKeys=${data.keys.join(',')}');

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _aiChatLog(
            'runAiTurn gateway returned error status=${response.statusCode} message=${_errorMessage(data, response.statusCode)}');
        throw _ChatApiException(_errorMessage(data, response.statusCode));
      }
      return data;
    } on TimeoutException {
      _aiChatLog(
          'runAiTurn timeout after ${DateTime.now().difference(startedAt).inMilliseconds}ms');
      throw const _ChatApiException(
          'La conexión tardó demasiado. Inténtalo otra vez.');
    } on FormatException catch (error) {
      _aiChatLog('runAiTurn JSON decode failed: $error');
      throw const _ChatApiException(
          'El asistente respondió con datos inválidos.');
    } on SocketException {
      _aiChatLog(
          'runAiTurn socket error while reaching ${Environment.apiBaseUrl}');
      throw const _ChatApiException(
          'No hay conexión con Call a Vet en este momento.');
    } finally {
      _aiChatLog('runAiTurn closing HttpClient');
      client.close(force: true);
    }
  }

  List<Map<String, dynamic>> _historyForApi() {
    final history = _messages
        .where((message) => message.includeInHistory)
        .map(
          (message) => {
            'role': message.isUser ? 'user' : 'assistant',
            'content': message.text,
            if (!message.isUser && message.result != null)
              'metadata': message.result!.payload.historyMetadata,
          },
        )
        .toList(growable: false);
    _aiChatLog(
        'historyForApi prepared count=${history.length} roles=${history.map((message) => message['role']).join(',')}');
    return history;
  }

  void _sendQuickReply(String service) {
    _aiChatLog('quickReply selected service=$service isSending=$_isSending');
    final text = switch (service) {
      'video' => 'Quiero una videollamada ahora con un veterinario.',
      'scheduled_video' =>
        'Quiero agendar una videollamada con un veterinario.',
      _ => 'Quiero continuar por chat con un veterinario.',
    };
    _sendUserMessage(text);
  }

  Future<void> _activateService(String service, _AiChatTurnResult result,
      {bool addUserBubble = true}) async {
    if (service == 'scheduled_video') {
      _sendQuickReply(service);
      return;
    }
    if (_isSending) {
      _aiChatLog('activateService ignored while busy service=$service');
      return;
    }
    final kind = service == 'video' ? 'video' : 'chat';
    _aiChatLog(
      'activateService start kind=$kind petId=${result.petId} vetId=${result.vetId} specialtyId=${result.specialtyId}',
    );
    setState(() {
      if (addUserBubble) {
        _messages.add(_ChatMessage.user(kind == 'video'
            ? 'Iniciar videollamada ahora.'
            : 'Iniciar chat con el veterinario.'));
      }
      _isSending = true;
    });
    _scrollToBottom();

    try {
      final start = await _startSession(kind, result);
      _aiChatLog(
          'activateService /sessions/start response keys=${start.keys.join(',')}');
      if (start['overage'] == true) {
        final exhaustedResult = result.withEntitlement(
          serviceType: kind,
          canUse: false,
          remaining: 0,
          reason: start['overageReason']?.toString(),
        );
        final offerMessage =
            await _aiEntitlementOfferMessage(kind, start, exhaustedResult);
        if (!mounted) return;
        setState(() {
          _messages.add(_ChatMessage.assistant(
            offerMessage,
            result: exhaustedResult,
            includeInHistory: false,
          ));
          _isSending = false;
        });
        _scrollToBottom();
        return;
      }
      await _completeStartedSession(kind, start);
    } catch (error) {
      _aiChatLog('activateService failed: ${error.runtimeType} $error');
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage.assistant(_friendlyError(error),
            includeInHistory: false));
        _isSending = false;
      });
      _scrollToBottom();
    }
  }

  Future<void> _purchaseSingleSession(
      String service, _AiChatTurnResult result) async {
    if (_isSending) {
      _aiChatLog('purchaseSingleSession ignored while busy service=$service');
      return;
    }
    final kind =
        service == 'video' || service == 'scheduled_video' ? 'video' : 'chat';
    _aiChatLog('purchaseSingleSession start kind=$kind');
    setState(() {
      _messages.add(_ChatMessage.user(kind == 'video'
          ? 'Comprar videollamada única.'
          : 'Comprar chat único.'));
      _isSending = true;
    });
    _scrollToBottom();

    try {
      final grant = await _postGatewayJson('/subscriptions/overage/dev-grant', {
        'type': kind,
        'quantity': 1,
      });
      _aiChatLog(
          'purchaseSingleSession dev grant response keys=${grant.keys.join(',')}');
      final start = await _startSession(kind, result);
      if (start['overage'] == true) {
        if (!mounted) return;
        setState(() {
          _messages.add(_ChatMessage.assistant(
            _paymentRequiredMessage(start),
            result: result.withEntitlement(
                serviceType: kind,
                canUse: false,
                remaining: 0,
                reason: start['overageReason']?.toString()),
            includeInHistory: false,
          ));
          _isSending = false;
        });
        _scrollToBottom();
        return;
      }
      await _completeStartedSession(kind, start);
    } catch (error) {
      _aiChatLog('purchaseSingleSession failed: ${error.runtimeType} $error');
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage.assistant(_friendlyError(error),
            includeInHistory: false));
        _isSending = false;
      });
      _scrollToBottom();
    }
  }

  Future<void> _openSubscriptionUpgrade(_AiChatTurnResult result) async {
    if (_isSending) return;
    _aiChatLog('openSubscriptionUpgrade in-chat start');
    setState(() {
      _messages.add(_ChatMessage.user('Mejorar mi suscripción.'));
      _isSending = true;
    });
    _scrollToBottom();

    try {
      final option =
          await _fetchSubscriptionUpgradeOption(result.commerceService);
      final message = await _aiUpgradePlanMessage(option, result);
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage.assistant(
          message,
          result: result.withUpgradePlan(option.targetPlan),
          includeInHistory: false,
        ));
        _isSending = false;
      });
      _scrollToBottom();
    } catch (error) {
      _aiChatLog('openSubscriptionUpgrade failed: ${error.runtimeType} $error');
      if (error is _ChatApiException &&
          error.message == _noUpgradePlanAvailableMessage) {
        final service = result.commerceService;
        final includedLabel =
            service == 'video' ? 'videollamadas incluidas' : 'chats incluidos';
        final oneOffLabel =
            service == 'video' ? 'una videollamada única' : 'un chat único';
        final fallbackResult = result.withEntitlement(
          serviceType: service,
          canUse: false,
          remaining: 0,
          reason: 'no_${service}_entitlement_left',
          upgradeUnavailable: true,
        );
        if (!mounted) return;
        setState(() {
          _messages.add(_ChatMessage.assistant(
            'No hay un plan superior con más $includedLabel disponible. Para seguir con esta consulta, puedes comprar $oneOffLabel desde el botón del chat.',
            result: fallbackResult,
            includeInHistory: false,
          ));
          _isSending = false;
        });
        _scrollToBottom();
        return;
      }
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage.assistant(_friendlyError(error),
            includeInHistory: false));
        _isSending = false;
      });
      _scrollToBottom();
    }
  }

  Future<void> _confirmSubscriptionUpgrade(
      _ChatSubscriptionPlan plan, _AiChatTurnResult result) async {
    if (_isSending) return;
    _aiChatLog(
        'confirmSubscriptionUpgrade start plan=${plan.code} service=${result.commerceService}');
    setState(() {
      _messages.add(_ChatMessage.user('Actualizar a ${plan.displayName}.'));
      _isSending = true;
    });
    _scrollToBottom();

    try {
      var upgrade = await _postGatewayJson(
          '/subscriptions/change-plan', {'code': plan.code});
      if (upgrade['ok'] != true &&
          upgrade['reason']?.toString() == 'no_active_subscription') {
        upgrade = await _postGatewayJson(
            '/subscriptions/activate-plan', {'code': plan.code});
      }
      if (upgrade['ok'] != true) {
        throw _ChatApiException(
            'No pude actualizar el plan: ${upgrade['reason']?.toString() ?? 'respuesta inválida'}');
      }

      final message = await _aiUpgradeConfirmedMessage(plan, result);
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage.assistant(message, includeInHistory: false));
        _isSending = false;
      });
      _scrollToBottom();

      if (result.canRetryActivationAfterUpgrade &&
          await _hasServiceAvailability(result.commerceService)) {
        await _activateService(result.commerceService, result,
            addUserBubble: false);
      } else if (result.canRetryActivationAfterUpgrade) {
        final message = await _aiPostUpgradeStillExhaustedMessage(plan, result);
        if (!mounted) return;
        setState(() {
          _messages.add(_ChatMessage.assistant(
            message,
            result: result.withEntitlement(
                serviceType: result.commerceService,
                canUse: false,
                remaining: 0,
                reason: 'no_${result.commerceService}_entitlement_left'),
            includeInHistory: false,
          ));
          _isSending = false;
        });
        _scrollToBottom();
      }
    } catch (error) {
      _aiChatLog(
          'confirmSubscriptionUpgrade failed: ${error.runtimeType} $error');
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage.assistant(_friendlyError(error),
            includeInHistory: false));
        _isSending = false;
      });
      _scrollToBottom();
    }
  }

  Future<_SubscriptionUpgradeOption> _fetchSubscriptionUpgradeOption(
      String service) async {
    final subscriptions = await _getGatewayJson('/subscriptions/my');
    final usageResponse = await _getGatewayJson('/subscriptions/usage/current');
    final plansResponse = await _getGatewayJson('/plans');
    final usage = _ChatSubscriptionUsage.fromJson(
        _asMap(usageResponse['usage']) ?? const {});
    final plans = (_asList(plansResponse['items']) ?? const [])
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .map(_ChatSubscriptionPlan.fromJson)
        .where((plan) =>
            plan.code.isNotEmpty &&
            (plan.includedChats > 0 || plan.includedVideos > 0) &&
            !plan.code.endsWith('_unit'))
        .toList();

    plans.sort((a, b) {
      final rank = a.rank.compareTo(b.rank);
      if (rank != 0) return rank;
      final price = a.monthlyCents.compareTo(b.monthlyCents);
      return price != 0 ? price : a.code.compareTo(b.code);
    });
    if (plans.isEmpty) {
      throw const _ChatApiException(
          'No pude cargar los planes disponibles. Inténtalo de nuevo.');
    }

    Map<String, dynamic>? activeRow;
    for (final item in _asList(subscriptions['data']) ?? const []) {
      final row = _asMap(item);
      if (row != null && _truthy(row['is_active_now'])) {
        activeRow = row;
        break;
      }
    }

    final currentCode =
        _asMap(activeRow?['plan'])?['code']?.toString().toLowerCase();
    final currentPlan =
        currentCode == null ? null : _findPlanByCode(plans, currentCode);
    final currentIndex = currentPlan == null
        ? -1
        : plans.indexWhere((plan) =>
            plan.code.toLowerCase() == currentPlan.code.toLowerCase());
    final targetPlan = plans.firstWhere(
      (plan) {
        final planIndex = plans.indexWhere(
            (item) => item.code.toLowerCase() == plan.code.toLowerCase());
        if (currentIndex >= 0 && planIndex <= currentIndex) {
          return false;
        }
        if (currentIndex < 0 &&
            currentPlan != null &&
            plan.monthlyCents <= currentPlan.monthlyCents) {
          return false;
        }
        return usage.remainingForPlan(plan, service) > 0;
      },
      orElse: () => const _ChatSubscriptionPlan.empty(),
    );

    if (targetPlan.code.isEmpty) {
      throw const _ChatApiException(_noUpgradePlanAvailableMessage);
    }

    return _SubscriptionUpgradeOption(
        currentPlan: currentPlan, targetPlan: targetPlan, usage: usage);
  }

  Future<String> _aiUpgradePlanMessage(
      _SubscriptionUpgradeOption option, _AiChatTurnResult result) async {
    final service = result.commerceService == 'video' ? 'videollamada' : 'chat';
    final prompt = [
      'Contexto interno de Call a Vet: el usuario tocó mejorar plan dentro del chat porque necesita más acceso a $service.',
      'Plan actual: ${option.currentPlan?.aiSummary ?? 'sin plan activo identificado en la app'}.',
      'Plan superior recomendado: ${option.targetPlan.aiSummary}.',
      'Uso actual del periodo: ${option.usage.aiSummary}.',
      'Escribe solo el mensaje visible para el usuario, en español, máximo dos frases.',
      'Describe beneficios concretos del plan superior sobre el actual con los datos de planes provistos.',
      'Cierra indicando que puede actualizar desde el botón del chat.',
      'No inventes precios, descuentos, beneficios, pagos, ni disponibilidad. No hagas preguntas de triaje.',
    ].join(' ');
    try {
      final response = await _runAiTurn(prompt, const []);
      final generated =
          _AiChatTurnResult.fromJson(response).payload.message.trim();
      if (generated.isNotEmpty) return generated;
    } catch (error) {
      _aiChatLog(
          'aiUpgradePlanMessage fallback after ${error.runtimeType}: $error');
    }
    return '${option.targetPlan.displayName} te da ${option.targetPlan.includedChats} chats y ${option.targetPlan.includedVideos} videollamadas incluidas para tener más margen de atención. Puedes actualizar desde el botón del chat.';
  }

  Future<String> _aiUpgradeConfirmedMessage(
      _ChatSubscriptionPlan plan, _AiChatTurnResult result) async {
    final service = result.commerceService == 'video' ? 'videollamada' : 'chat';
    final prompt = [
      'Contexto interno de Call a Vet: el usuario actualizó su suscripción al plan ${plan.displayName} dentro del chat.',
      'Plan actualizado: ${plan.aiSummary}.',
      'Escribe solo el mensaje visible para el usuario, en español, una frase breve.',
      'Confirma la actualización y explica que ahora volverás a validar la disponibilidad de $service si aplica.',
      'No menciones IDs ni detalles técnicos.',
    ].join(' ');
    try {
      final response = await _runAiTurn(prompt, const []);
      final generated =
          _AiChatTurnResult.fromJson(response).payload.message.trim();
      if (generated.isNotEmpty) return generated;
    } catch (error) {
      _aiChatLog(
          'aiUpgradeConfirmedMessage fallback after ${error.runtimeType}: $error');
    }
    return 'Tu suscripción se actualizó a ${plan.displayName}; voy a volver a validar la disponibilidad de $service.';
  }

  Future<String> _aiPostUpgradeStillExhaustedMessage(
      _ChatSubscriptionPlan plan, _AiChatTurnResult result) async {
    final service =
        result.commerceService == 'video' ? 'videollamadas' : 'chats';
    final prompt = [
      'Contexto interno de Call a Vet: el usuario actualizó a ${plan.displayName}, pero al revalidar aún no quedan $service incluidos disponibles este periodo.',
      'Escribe solo el mensaje visible para el usuario, en español, máximo dos frases.',
      'Explica de forma clara que la actualización se aplicó, pero el cupo del periodo sigue agotado para ese servicio, y ofrece comprar una sesión única o revisar otro plan.',
      'No menciones IDs ni detalles técnicos.',
    ].join(' ');
    try {
      final response = await _runAiTurn(prompt, const []);
      final generated =
          _AiChatTurnResult.fromJson(response).payload.message.trim();
      if (generated.isNotEmpty) return generated;
    } catch (error) {
      _aiChatLog(
          'aiPostUpgradeStillExhaustedMessage fallback after ${error.runtimeType}: $error');
    }
    return 'La actualización a ${plan.displayName} se aplicó, pero el cupo de $service del periodo sigue agotado. Puedes comprar una sesión única o revisar otro plan desde aquí.';
  }

  Future<bool> _hasServiceAvailability(String service) async {
    final response = await _getGatewayJson('/subscriptions/usage/current');
    final usage =
        _ChatSubscriptionUsage.fromJson(_asMap(response['usage']) ?? const {});
    return service == 'video'
        ? usage.remainingVideos > 0
        : usage.remainingChats > 0;
  }

  Future<void> _completeStartedSession(
      String kind, Map<String, dynamic> start) async {
    final sessionId = _uuidOrNull(start['sessionId']?.toString() ?? '');
    if (sessionId == null) {
      throw const _ChatApiException(
          'No pude activar la consulta: el servidor no devolvió una sesión válida.');
    }

    if (kind == 'video') {
      _aiChatLog(
          'completeStartedSession video session active sessionId=$sessionId; navigating');
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage.assistant(
            'Videollamada activada. Te conecto con el veterinario.',
            includeInHistory: false));
        _isSending = false;
      });
      _cacheSessionMessages(sessionId);
      _scrollToBottom();
      context.go('/video/${Uri.encodeComponent(sessionId)}');
      return;
    }

    _aiChatLog(
        'completeStartedSession chat session active sessionId=$sessionId; navigating');
    if (!mounted) return;
    setState(() {
      _messages.add(_ChatMessage.assistant(
          'Chat con veterinario activado. Te llevo a la conversación.',
          includeInHistory: false));
      _isSending = false;
    });
    _scrollToBottom();
    context.go('/chat/${Uri.encodeComponent(sessionId)}');
  }

  void _cacheSessionMessages(String sessionId) {
    _sessionMessageCache[sessionId] = List<_ChatMessage>.from(_messages);
    _aiChatLog(
        'cached session chat sessionId=$sessionId messages=${_messages.length}');
  }

  Future<Map<String, dynamic>> _startSession(
      String kind, _AiChatTurnResult result) {
    final history = _historyForApi();
    return _postGatewayJson('/sessions/start', {
      'kind': kind,
      if (result.petId != null) 'petId': result.petId,
      if (result.vetId != null) 'vetId': result.vetId,
      if (result.specialtyId != null) 'specialtyId': result.specialtyId,
      'priority': result.payload.urgency,
      'aiContext': result.handoffContext(history),
    });
  }

  Future<Map<String, dynamic>> _postGatewayJson(
      String path, Map<String, dynamic> body) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      throw const _ChatApiException(
          'Tu sesión expiró. Vuelve a iniciar sesión.');
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final startedAt = DateTime.now();
    try {
      final uri = Uri.parse('${Environment.apiBaseUrl}$path');
      _aiChatLog('gateway POST $uri bodyKeys=${body.keys.join(',')}');
      final request =
          await client.postUrl(uri).timeout(const Duration(seconds: 10));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set('x-cav-actor-role', 'user');
      request.add(utf8.encode(jsonEncode(body)));

      final response =
          await request.close().timeout(const Duration(seconds: 30));
      final rawBody = await utf8.decoder.bind(response).join();
      _aiChatLog(
        'gateway POST $path status=${response.statusCode} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} '
        'bodyPreview="${_preview(rawBody, max: 420)}"',
      );
      final decoded =
          rawBody.trim().isEmpty ? <String, dynamic>{} : jsonDecode(rawBody);
      final data = _asMap(decoded) ?? <String, dynamic>{};
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _ChatApiException(_errorMessage(data, response.statusCode));
      }
      return data;
    } on TimeoutException {
      throw const _ChatApiException(
          'La conexión tardó demasiado. Inténtalo otra vez.');
    } on FormatException {
      throw const _ChatApiException(
          'El servidor respondió con datos inválidos.');
    } on SocketException {
      throw const _ChatApiException(
          'No hay conexión con Call a Vet en este momento.');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _patchGatewayJson(
      String path, Map<String, dynamic> body) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      throw const _ChatApiException(
          'Tu sesión expiró. Vuelve a iniciar sesión.');
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final startedAt = DateTime.now();
    try {
      final uri = Uri.parse('${Environment.apiBaseUrl}$path');
      _aiChatLog('gateway PATCH $uri bodyKeys=${body.keys.join(',')}');
      final request =
          await client.patchUrl(uri).timeout(const Duration(seconds: 10));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set('x-cav-actor-role', 'user');
      request.add(utf8.encode(jsonEncode(body)));

      final response =
          await request.close().timeout(const Duration(seconds: 30));
      final rawBody = await utf8.decoder.bind(response).join();
      _aiChatLog(
        'gateway PATCH $path status=${response.statusCode} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} '
        'bodyPreview="${_preview(rawBody, max: 420)}"',
      );
      final decoded =
          rawBody.trim().isEmpty ? <String, dynamic>{} : jsonDecode(rawBody);
      final data = _asMap(decoded) ?? <String, dynamic>{};
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _ChatApiException(_errorMessage(data, response.statusCode));
      }
      return data;
    } on TimeoutException {
      throw const _ChatApiException(
          'La conexión tardó demasiado. Inténtalo otra vez.');
    } on FormatException {
      throw const _ChatApiException(
          'El servidor respondió con datos inválidos.');
    } on SocketException {
      throw const _ChatApiException(
          'No hay conexión con Call a Vet en este momento.');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _getGatewayJson(String path) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      throw const _ChatApiException(
          'Tu sesión expiró. Vuelve a iniciar sesión.');
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final startedAt = DateTime.now();
    try {
      final uri = Uri.parse('${Environment.apiBaseUrl}$path');
      _aiChatLog('gateway GET $uri');
      final request =
          await client.getUrl(uri).timeout(const Duration(seconds: 10));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set('x-cav-actor-role', 'user');

      final response =
          await request.close().timeout(const Duration(seconds: 30));
      final rawBody = await utf8.decoder.bind(response).join();
      _aiChatLog(
        'gateway GET $path status=${response.statusCode} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} '
        'bodyPreview="${_preview(rawBody, max: 420)}"',
      );
      final decoded =
          rawBody.trim().isEmpty ? <String, dynamic>{} : jsonDecode(rawBody);
      final data = _asMap(decoded) ?? <String, dynamic>{};
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _ChatApiException(_errorMessage(data, response.statusCode));
      }
      return data;
    } on TimeoutException {
      throw const _ChatApiException(
          'La conexión tardó demasiado. Inténtalo otra vez.');
    } on FormatException {
      throw const _ChatApiException(
          'El servidor respondió con datos inválidos.');
    } on SocketException {
      throw const _ChatApiException(
          'No hay conexión con Call a Vet en este momento.');
    } finally {
      client.close(force: true);
    }
  }

  String _paymentRequiredMessage(Map<String, dynamic> response) {
    final payment = _asMap(response['payment']);
    final url = payment?['url']?.toString();
    if (url != null && url.isNotEmpty) {
      return 'Para activar esta consulta necesitas completar el pago. Link de checkout: $url';
    }
    final reason = response['overageReason']?.toString() ?? 'no_entitlement';
    return 'Para activar esta consulta necesitas pago o crédito adicional. Motivo: $reason';
  }

  Future<String> _aiEntitlementOfferMessage(
      String kind, Map<String, dynamic> start, _AiChatTurnResult result) async {
    final service = kind == 'video' ? 'videollamada' : 'chat';
    final reason = start['overageReason']?.toString() ??
        result.serviceAccessReason ??
        'no_entitlement';
    final prompt = [
      'Contexto interno de Call a Vet: el usuario intentó activar una $service, pero el servidor confirmó que no tiene disponibilidad incluida en su suscripción.',
      'Motivo técnico: $reason.',
      'Redacta solo el mensaje visible para el usuario, en español, máximo dos frases.',
      'Debe ofrecer comprar una $service única o mejorar su suscripción.',
      'No menciones IDs, checkout, herramientas, pagos externos, ni que este mensaje viene de contexto interno.',
      'No hagas más preguntas de triaje.',
    ].join(' ');

    try {
      final response = await _runAiTurn(prompt, const []);
      final generated =
          _AiChatTurnResult.fromJson(response).payload.message.trim();
      if (generated.isNotEmpty) return generated;
    } catch (error) {
      _aiChatLog(
          'aiEntitlementOfferMessage fallback after ${error.runtimeType}: $error');
    }

    return 'Tu plan ya no tiene $service incluida disponible. Puedes comprar una $service única o mejorar tu suscripción.';
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
          ignoring: _isReturningHome,
          child: AnimatedOpacity(
            duration: _returnHomeFadeDuration,
            curve: Curves.easeOutCubic,
            opacity: _isReturningHome ? 0 : 1,
            child: thread,
          ),
        ),
      ),
    );
  }

  Widget _buildThread(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final topChromeHeight = topInset + 90;
    final topFadeHeight = topInset + 132;
    final bottomFadeHeight = bottomInset + 150;
    final showHomeIntro = _showsHomeIntro;
    final messageList = ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(
        18,
        topChromeHeight,
        18,
        bottomInset + 102,
      ),
      itemCount: (showHomeIntro ? 1 : 0) + _messages.length,
      itemBuilder: (context, index) {
        final introCount = showHomeIntro ? 1 : 0;
        if (showHomeIntro && index == 0) {
          return _HomeChatIntro(displayName: _homeDisplayName);
        }
        final messageIndex = index - introCount;
        final message = _messages[messageIndex];
        final isFirstUserMessage = message.isUser &&
            !_messages.take(messageIndex).any((message) => message.isUser);
        final userTurnsBeforeOrAtMessage = _messages
            .take(messageIndex + 1)
            .where((message) => message.isUser)
            .length;
        return _AnimatedMessageEntry(
          key: ValueKey(message.id),
          isUser: message.isUser,
          isFirstUserMessage: isFirstUserMessage,
          child: _MessageBubble(
            message: message,
            sending: _isSending,
            canShowActions: userTurnsBeforeOrAtMessage >= 2,
            onServiceSelected: _activateService,
            onOneOffPurchaseSelected: _purchaseSingleSession,
            onUpgradeSelected: _openSubscriptionUpgrade,
            onPlanUpgradeConfirmed: _confirmSubscriptionUpgrade,
            onRejoinVideo: _openVideoFromChat,
            onSurveyAction: _handleSurveyAction,
          ),
        );
      },
    );
    final fadedMessageList = _MessageOpacityFade(
      topFadeHeight: topFadeHeight,
      bottomFadeHeight: bottomFadeHeight,
      child: messageList,
    );

    return Stack(
      children: [
        Positioned.fill(
          child: fadedMessageList,
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: _ChatHeader(
              onBack: () => unawaited(_returnHome()),
              onEnd: _isConsultChatRoute && !_consultClosed
                  ? () => unawaited(_endConsultFromOwner())
                  : null,
              ending: _endingConsult,
              statusText: _isConsultChatRoute
                  ? _vetTyping
                      ? 'veterinario escribiendo...'
                      : _vetOnline
                          ? 'veterinario en línea'
                          : 'consulta activa'
                  : null,
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _ChatComposer(
            controller: _inputCtrl,
            focusNode: _focusNode,
            sending: _isSending ||
                _endingConsult ||
                (_consultLoading && _messages.isEmpty),
            includeBottomInset: true,
            onSend: _sendComposerMessage,
          ),
        ),
      ],
    );
  }

  void _openVideoFromChat(String sessionId) {
    final normalizedSessionId = _uuidOrNull(sessionId);
    if (normalizedSessionId == null) return;
    _aiChatLog(
        'post-call rejoin video action selected sessionId=$normalizedSessionId');
    _cacheSessionMessages(normalizedSessionId);
    context.go('/video/${Uri.encodeComponent(normalizedSessionId)}');
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

class _HomeChatIntro extends StatelessWidget {
  const _HomeChatIntro({required this.displayName});

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
                  fontFamily: 'ABCDiatype',
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '¿Cómo podemos asistirte hoy?',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontFamily: 'ABCDiatype',
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

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.onBack,
    required this.onEnd,
    required this.ending,
    this.statusText,
  });

  final VoidCallback onBack;
  final VoidCallback? onEnd;
  final bool ending;
  final String? statusText;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 24, 18, 0),
      child: Row(
        children: [
          GestureDetector(
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
          if (statusText != null) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                statusText!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.62),
                  fontSize: 12,
                  fontFamily: 'ABCDiatype',
                ),
              ),
            ),
          ] else
            const Spacer(),
          if (onEnd != null)
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

class _AnimatedMessageEntry extends StatelessWidget {
  const _AnimatedMessageEntry({
    super.key,
    required this.isUser,
    required this.isFirstUserMessage,
    required this.child,
  });

  final bool isUser;
  final bool isFirstUserMessage;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: isFirstUserMessage ? 520 : 260),
      curve: isFirstUserMessage ? Curves.easeOutQuart : Curves.easeOutCubic,
      builder: (context, value, child) {
        final slideX = (isUser ? 10.0 : -10.0) * (1 - value);
        final slideY = (isFirstUserMessage ? 34.0 : 5.0) * (1 - value);
        final scale = isFirstUserMessage ? 0.98 + (value * 0.02) : 1.0;
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(slideX, slideY),
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.bottomRight,
              child: child,
            ),
          ),
        );
      },
      child: child,
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.sending,
    required this.canShowActions,
    required this.onServiceSelected,
    required this.onOneOffPurchaseSelected,
    required this.onUpgradeSelected,
    required this.onPlanUpgradeConfirmed,
    required this.onRejoinVideo,
    required this.onSurveyAction,
  });

  final _ChatMessage message;
  final bool sending;
  final bool canShowActions;
  final void Function(String service, _AiChatTurnResult result)
      onServiceSelected;
  final void Function(String service, _AiChatTurnResult result)
      onOneOffPurchaseSelected;
  final void Function(_AiChatTurnResult result) onUpgradeSelected;
  final void Function(_ChatSubscriptionPlan plan, _AiChatTurnResult result)
      onPlanUpgradeConfirmed;
  final ValueChanged<String> onRejoinVideo;
  final ValueChanged<_SurveyActionChoice> onSurveyAction;

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final bubbleColor = isUser ? const Color(0xFF242426) : Colors.black;
    const textColor = Colors.white;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final widthFactor = isUser ? 0.66 : 0.72;
    final fixedCap = isUser ? 350.0 : 380.0;
    final maxBubbleWidth = math.min(viewportWidth * widthFactor, fixedCap);
    const messageTextStyle = TextStyle(
      color: textColor,
      fontSize: 15,
      fontWeight: FontWeight.w400,
      height: 1.34,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxBubbleWidth,
          ),
          child: Column(
            crossAxisAlignment:
                isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                  child: isUser
                      ? Text(message.text, style: messageTextStyle)
                      : _AssistantMessageContent(
                          text: message.text,
                          payload: message.result?.payload,
                          style: messageTextStyle,
                        ),
                ),
              ),
              if (message.receiptLabel != null) ...[
                const SizedBox(height: 4),
                Text(
                  message.receiptLabel!,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.38),
                    fontSize: 10,
                    fontFamily: 'ABCDiatype',
                  ),
                ),
              ],
              if (!isUser &&
                  canShowActions &&
                  message.result?.payload.canShowActions == true &&
                  (message.result?.payload.recommendedService != null ||
                      message.result?.upgradePlan != null)) ...[
                const SizedBox(height: 8),
                _HandoffPanel(
                  result: message.result!,
                  sending: sending,
                  onServiceSelected: onServiceSelected,
                  onOneOffPurchaseSelected: onOneOffPurchaseSelected,
                  onUpgradeSelected: onUpgradeSelected,
                  onPlanUpgradeConfirmed: onPlanUpgradeConfirmed,
                ),
              ],
              if (!isUser && message.rejoinSessionId != null) ...[
                const SizedBox(height: 8),
                _ServiceButton(
                  label: 'Volver a videollamada',
                  selected: true,
                  enabled: !sending,
                  onTap: () => onRejoinVideo(message.rejoinSessionId!),
                ),
              ],
              if (!isUser && message.surveyAction != null) ...[
                const SizedBox(height: 8),
                _SurveyActionPanel(
                  action: message.surveyAction!,
                  sending: sending,
                  onSelected: onSurveyAction,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AssistantMessageContent extends StatelessWidget {
  const _AssistantMessageContent({
    required this.text,
    required this.payload,
    required this.style,
  });

  final String text;
  final _AiChatPayload? payload;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final blocks = payload?.hasDisplayBlocks == true
        ? payload!.displayBlocks
        : const <_AiMessageBlock>[];
    if (blocks.isEmpty) {
      return Text(_readableAssistantText(text), style: style);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < blocks.length; index++)
          Padding(
            padding:
                EdgeInsets.only(bottom: index == blocks.length - 1 ? 0 : 8),
            child: _AssistantMessageBlockView(
              block: blocks[index],
              style: style,
            ),
          ),
      ],
    );
  }
}

class _AssistantMessageBlockView extends StatelessWidget {
  const _AssistantMessageBlockView({
    required this.block,
    required this.style,
  });

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
        return _AssistantMessageList(
          items: block.items,
          numbered: true,
          style: style,
        );
      case _AiMessageBlockType.bulletList:
        return _AssistantMessageList(
          items: block.items,
          numbered: false,
          style: style,
        );
    }
  }
}

class _AssistantMessageList extends StatelessWidget {
  const _AssistantMessageList({
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
            child: _AssistantMessageListRow(
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

class _AssistantMessageListRow extends StatelessWidget {
  const _AssistantMessageListRow({
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

class _HandoffPanel extends StatelessWidget {
  const _HandoffPanel({
    required this.result,
    required this.sending,
    required this.onServiceSelected,
    required this.onOneOffPurchaseSelected,
    required this.onUpgradeSelected,
    required this.onPlanUpgradeConfirmed,
  });

  final _AiChatTurnResult result;
  final bool sending;
  final void Function(String service, _AiChatTurnResult result)
      onServiceSelected;
  final void Function(String service, _AiChatTurnResult result)
      onOneOffPurchaseSelected;
  final void Function(_AiChatTurnResult result) onUpgradeSelected;
  final void Function(_ChatSubscriptionPlan plan, _AiChatTurnResult result)
      onPlanUpgradeConfirmed;

  @override
  Widget build(BuildContext context) {
    final payload = result.payload;
    if (!payload.canShowActions) return const SizedBox.shrink();
    final upgradePlan = result.upgradePlan;
    if (upgradePlan != null) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _ServiceButton(
            label: 'actualizar a ${upgradePlan.displayName}',
            selected: true,
            enabled: !sending,
            onTap: () => onPlanUpgradeConfirmed(upgradePlan, result),
          ),
        ],
      );
    }
    final recommended = payload.recommendedService;
    if (recommended == null) return const SizedBox.shrink();
    if (result.entitlementExhaustedForRecommendedService) {
      final service = result.commerceService;
      final recommendedService = payload.recommendedService == 'scheduled_video'
          ? 'video'
          : payload.recommendedService;
      final canAlsoUseRecommended = result.commerceServiceOverride == null &&
          recommendedService != null &&
          recommendedService != service &&
          (recommendedService == 'chat' || recommendedService == 'video');
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (canAlsoUseRecommended)
            _ServiceButton(
              label: _serviceLabel(recommendedService),
              selected: true,
              enabled: !sending,
              onTap: () => onServiceSelected(recommendedService, result),
            ),
          if (!result.noActiveSubscription)
            _ServiceButton(
              label: _commerceServiceLabel(service),
              selected: true,
              enabled: !sending,
              onTap: () => onOneOffPurchaseSelected(service, result),
            ),
          if (!result.upgradeUnavailable)
            _ServiceButton(
              label: 'Mejorar mi plan',
              selected: false,
              enabled: !sending,
              onTap: () => onUpgradeSelected(result),
            ),
        ],
      );
    }
    final services = ['chat', 'video', 'scheduled_video'];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: services.map((service) {
        final selected = service == recommended;
        return _ServiceButton(
          label: _serviceLabel(service),
          selected: selected,
          enabled: !sending,
          onTap: () => onServiceSelected(service, result),
        );
      }).toList(growable: false),
    );
  }

  String _serviceLabel(String service) {
    return switch (service) {
      'video' => 'Iniciar videollamada con especialista',
      'scheduled_video' => 'Agendar consulta por videollamada',
      _ => 'Iniciar chat con veterinario',
    };
  }

  String _commerceServiceLabel(String service) {
    return service == 'video'
        ? 'Comprar consulta por videollamada'
        : 'Comprar consulta por chat';
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
            color: Colors.white,
            borderRadius: BorderRadius.circular(30),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.black,
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

class _SurveyActionPanel extends StatelessWidget {
  const _SurveyActionPanel({
    required this.action,
    required this.sending,
    required this.onSelected,
  });

  final _SurveyAction action;
  final bool sending;
  final ValueChanged<_SurveyActionChoice> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: action.choices.map((choice) {
        return _ServiceButton(
          label: choice.label,
          selected: choice.selected,
          enabled: !sending,
          onTap: () => onSelected(choice),
        );
      }).toList(growable: false),
    );
  }
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
        child: AnimatedBuilder(
          animation: focusNode,
          builder: (context, child) {
            return _ComposerFrame(
              active: focusNode.hasFocus || sending,
              thinking: sending,
              child: child!,
            );
          },
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
                      hintText: sending ? 'Pensando...' : 'escribir mensaje...',
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
                      disabledBackgroundColor:
                          Colors.white.withValues(alpha: 0.25),
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

class _ComposerFrame extends StatefulWidget {
  const _ComposerFrame({
    required this.child,
    required this.active,
    required this.thinking,
  });

  final Widget child;
  final bool active;
  final bool thinking;

  @override
  State<_ComposerFrame> createState() => _ComposerFrameState();
}

class _ComposerFrameState extends State<_ComposerFrame>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 14000),
    );
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _ComposerFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final phase = _controller.value * math.pi * 2;
        final pulse =
            widget.active ? 0.72 + (math.sin(phase * 0.82) + 1) * 0.12 : 1.0;
        final drift = widget.active
            ? math.sin(phase) * 7.5 + math.sin(phase * 2.15) * 2.0
            : 0.0;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(28),
            boxShadow: widget.active
                ? [
                    BoxShadow(
                      color: const Color(0xFF57546F).withValues(
                          alpha: (widget.thinking ? 0.12 : 0.075) * pulse),
                      blurRadius: widget.thinking ? 22 : 14,
                      spreadRadius: -8,
                      offset: Offset(drift, 0),
                    ),
                  ]
                : null,
          ),
          child: CustomPaint(
            foregroundPainter: _ComposerOutlinePainter(
              progress: _controller.value,
              thinking: widget.thinking,
            ),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

class _ComposerOutlinePainter extends CustomPainter {
  const _ComposerOutlinePainter(
      {required this.progress, required this.thinking});

  final double progress;
  final bool thinking;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect =
        RRect.fromRectAndRadius(rect.deflate(0.7), const Radius.circular(28));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thinking ? 1.15 : 1;

    if (thinking) {
      paint.shader = SweepGradient(
        transform: GradientRotation(progress * math.pi * 2),
        colors: const [
          Color(0xCCFFFFFF),
          Color(0x88648FD8),
          Color(0x995A5578),
          Color(0xCCFFFFFF),
        ],
      ).createShader(rect);
    } else {
      paint.color = Colors.white.withValues(alpha: 0.055);
    }

    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant _ComposerOutlinePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.thinking != thinking;
  }
}

enum _ChatRole { user, vet, assistant }

class _ChatMessage {
  _ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    this.senderId,
    this.clientKey,
    this.streamOrder,
    this.deliveredByOther = false,
    this.readByOther = false,
    this.result,
    this.rejoinSessionId,
    this.surveyAction,
    this.includeInHistory = true,
  });

  factory _ChatMessage.user(String text, {bool includeInHistory = true}) {
    return _ChatMessage(
      id: _nextChatMessageId(),
      role: _ChatRole.user,
      text: text,
      includeInHistory: includeInHistory,
    );
  }

  factory _ChatMessage.assistant(
    String text, {
    _AiChatTurnResult? result,
    bool includeInHistory = true,
    String? rejoinSessionId,
    _SurveyAction? surveyAction,
  }) {
    return _ChatMessage(
      id: _nextChatMessageId(),
      role: _ChatRole.assistant,
      text: text,
      result: result,
      rejoinSessionId: rejoinSessionId,
      surveyAction: surveyAction,
      includeInHistory: includeInHistory,
    );
  }

  factory _ChatMessage.consultFromJson(Map<String, dynamic> json) {
    final roleRaw = json['role']?.toString().toLowerCase() ?? '';
    final role = switch (roleRaw) {
      'user' => _ChatRole.user,
      'vet' => _ChatRole.vet,
      _ => _ChatRole.assistant,
    };
    return _ChatMessage(
      id: json['id']?.toString() ?? _nextChatMessageId(),
      role: role,
      text: json['content']?.toString() ?? '',
      senderId: json['sender_id']?.toString(),
      clientKey: json['client_key']?.toString(),
      streamOrder: _asInt(json['stream_order']),
      includeInHistory: false,
    );
  }

  final String id;
  final _ChatRole role;
  final String text;
  final String? senderId;
  final String? clientKey;
  final int? streamOrder;
  final bool deliveredByOther;
  final bool readByOther;
  final _AiChatTurnResult? result;
  final String? rejoinSessionId;
  final _SurveyAction? surveyAction;
  final bool includeInHistory;

  bool get isUser => role == _ChatRole.user;

  String? get receiptLabel {
    if (!isUser || streamOrder == null) return null;
    if (readByOther) return 'leído';
    if (deliveredByOther) return 'entregado';
    return null;
  }

  _ChatMessage copyWith({
    bool? deliveredByOther,
    bool? readByOther,
  }) {
    return _ChatMessage(
      id: id,
      role: role,
      text: text,
      senderId: senderId,
      clientKey: clientKey,
      streamOrder: streamOrder,
      deliveredByOther: deliveredByOther ?? this.deliveredByOther,
      readByOther: readByOther ?? this.readByOther,
      result: result,
      rejoinSessionId: rejoinSessionId,
      surveyAction: surveyAction,
      includeInHistory: includeInHistory,
    );
  }

  _ChatMessage withReceiptFrom(_ChatMessage previous) {
    return copyWith(
      deliveredByOther: previous.deliveredByOther,
      readByOther: previous.readByOther,
    );
  }
}

enum _SurveyStep { prompt, vetScore, appScore, feedback }

enum _SurveyActionType {
  startNow,
  later,
  dismiss,
  vetScore,
  appScore,
  skipFeedback,
}

class _SurveyAction {
  const _SurveyAction({
    required this.survey,
    required this.step,
    required this.choices,
  });

  factory _SurveyAction.prompt(_ConsultSurvey survey) {
    return _SurveyAction(
      survey: survey,
      step: _SurveyStep.prompt,
      choices: [
        _SurveyActionChoice(
          survey: survey,
          type: _SurveyActionType.startNow,
          label: 'Sí, calificar ahora',
          selected: true,
        ),
        _SurveyActionChoice(
          survey: survey,
          type: _SurveyActionType.later,
          label: 'Más tarde',
        ),
        _SurveyActionChoice(
          survey: survey,
          type: _SurveyActionType.dismiss,
          label: 'Descartar',
        ),
      ],
    );
  }

  factory _SurveyAction.score(_ConsultSurvey survey, _SurveyStep step) {
    final type = step == _SurveyStep.vetScore
        ? _SurveyActionType.vetScore
        : _SurveyActionType.appScore;
    return _SurveyAction(
      survey: survey,
      step: step,
      choices: _surveyScoreOptions
          .map((option) => _SurveyActionChoice(
                survey: survey,
                type: type,
                label: option.label,
                score: option.score,
                selected: option.score == 5,
              ))
          .toList(growable: false),
    );
  }

  factory _SurveyAction.feedback(_ConsultSurvey survey) {
    return _SurveyAction(
      survey: survey,
      step: _SurveyStep.feedback,
      choices: [
        _SurveyActionChoice(
          survey: survey,
          type: _SurveyActionType.skipFeedback,
          label: 'Omitir',
        ),
      ],
    );
  }

  final _ConsultSurvey survey;
  final _SurveyStep step;
  final List<_SurveyActionChoice> choices;

  String get surveyId => survey.id;
}

class _SurveyActionChoice {
  const _SurveyActionChoice({
    required this.survey,
    required this.type,
    required this.label,
    this.score,
    this.selected = false,
  });

  final _ConsultSurvey survey;
  final _SurveyActionType type;
  final String label;
  final int? score;
  final bool selected;
}

class _SurveyScoreOption {
  const _SurveyScoreOption(this.label, this.score);

  final String label;
  final int score;
}

const _surveyScoreOptions = [
  _SurveyScoreOption('Excelente', 5),
  _SurveyScoreOption('Buena', 4),
  _SurveyScoreOption('Regular', 3),
  _SurveyScoreOption('Mala', 2),
  _SurveyScoreOption('Pésima', 1),
];

class _ActiveSurveyFeedback {
  const _ActiveSurveyFeedback({required this.survey});

  final _ConsultSurvey survey;
}

class _SurveyResponse {
  const _SurveyResponse({
    required this.eligible,
    required this.reason,
    required this.survey,
  });

  factory _SurveyResponse.fromJson(Map<String, dynamic> json) {
    final surveyMap = _asMap(json['survey']);
    return _SurveyResponse(
      eligible: json['eligible'] == true,
      reason: json['reason']?.toString(),
      survey: surveyMap == null ? null : _ConsultSurvey.fromJson(surveyMap),
    );
  }

  final bool eligible;
  final String? reason;
  final _ConsultSurvey? survey;
}

class _ConsultSurvey {
  _ConsultSurvey({
    required this.id,
    required this.sessionId,
    required this.status,
    required this.vetAssistanceScore,
    required this.appServiceScore,
  });

  factory _ConsultSurvey.fromJson(Map<String, dynamic> json) {
    return _ConsultSurvey(
      id: json['id']?.toString() ?? '',
      sessionId: json['sessionId']?.toString() ?? '',
      status: json['status']?.toString() ?? 'pending',
      vetAssistanceScore: _toInt(json['vetAssistanceScore']),
      appServiceScore: _toInt(json['appServiceScore']),
    );
  }

  final String id;
  final String sessionId;
  final String status;
  final int? vetAssistanceScore;
  final int? appServiceScore;
}

class _AiChatTurnResult {
  const _AiChatTurnResult({
    required this.payload,
    this.aiEventId,
    this.petId,
    this.specialtyId,
    this.vetId,
    this.specialtyName,
    this.vetName,
    this.serviceAccessType,
    this.serviceCanUse,
    this.serviceAccessReason,
    this.commerceServiceOverride,
    this.upgradePlan,
    this.upgradeUnavailable = false,
    this.remaining,
  });

  factory _AiChatTurnResult.fromJson(Map<String, dynamic> json) {
    final payload =
        _AiChatPayload.fromJson(_asMap(json['payload']) ?? <String, dynamic>{});
    final aiEventId = _uuidFrom(json['eventId']);
    String? petId;
    String? specialtyId;
    String? vetId;
    String? specialtyName;
    String? vetName;
    String? serviceAccessType;
    bool? serviceCanUse;
    String? serviceAccessReason;
    int? remaining;
    final toolNames = <String>[];

    for (final item in _asList(json['toolResults']) ?? const []) {
      final tool = _asMap(item);
      final name = tool?['name']?.toString();
      if (name != null) toolNames.add(name);
      final output = _asMap(tool?['output']);
      if (name == 'recommend_specialty') {
        petId ??= _uuidFrom(output?['petId']);
        final specialty = _asMap(output?['specialty']);
        specialtyId ??= _uuidFrom(specialty?['id']);
        specialtyName = specialty?['name']?.toString();
      }
      if (name == 'find_vets') {
        specialtyId ??= _uuidFrom(output?['specialtyId']);
        final vets = _asList(output?['vets']);
        final firstVet =
            vets == null || vets.isEmpty ? null : _asMap(vets.first);
        vetId ??= _uuidFrom(firstVet?['id']);
        vetName = firstVet?['full_name']?.toString();
      }
      if (name == 'check_service_access') {
        serviceAccessType = output?['serviceType']?.toString();
        final canUseValue = output?['canUse'];
        serviceCanUse = canUseValue is bool ? canUseValue : null;
        serviceAccessReason = output?['reason']?.toString();
        final value = output?['remaining'];
        remaining = value is num
            ? value.toInt()
            : int.tryParse(value?.toString() ?? '');
      }
    }

    _aiChatLog(
      'AiChatTurnResult.fromJson payload={urgency:${payload.urgency}, recommendedService:${payload.recommendedService}, '
      'actionLabel:${payload.actionLabel}, safetyEscalation:${payload.safetyEscalation}, messageLength:${payload.message.length}} '
      'toolNames=${toolNames.join(',')} petId=$petId specialty=$specialtyName specialtyId=$specialtyId vet=$vetName vetId=$vetId '
      'serviceAccessType=$serviceAccessType canUse=$serviceCanUse reason=$serviceAccessReason remaining=$remaining',
    );

    return _AiChatTurnResult(
      payload: payload,
      aiEventId: aiEventId,
      petId: petId,
      specialtyId: specialtyId,
      vetId: vetId,
      specialtyName: specialtyName,
      vetName: vetName,
      serviceAccessType: serviceAccessType,
      serviceCanUse: serviceCanUse,
      serviceAccessReason: serviceAccessReason,
      remaining: remaining,
    );
  }

  final _AiChatPayload payload;
  final String? aiEventId;
  final String? petId;
  final String? specialtyId;
  final String? vetId;
  final String? specialtyName;
  final String? vetName;
  final String? serviceAccessType;
  final bool? serviceCanUse;
  final String? serviceAccessReason;
  final String? commerceServiceOverride;
  final _ChatSubscriptionPlan? upgradePlan;
  final bool upgradeUnavailable;
  final int? remaining;

  String get commerceService {
    if (commerceServiceOverride == 'video' ||
        commerceServiceOverride == 'chat') {
      return commerceServiceOverride!;
    }
    final recommended = payload.recommendedService == 'scheduled_video'
        ? 'video'
        : payload.recommendedService;
    final accessType =
        serviceAccessType == 'video' || serviceAccessType == 'chat'
            ? serviceAccessType
            : null;
    return accessType ?? (recommended == 'video' ? 'video' : 'chat');
  }

  bool get noActiveSubscription =>
      serviceAccessReason == 'no_active_subscription';

  bool get canRetryActivationAfterUpgrade {
    return serviceCanUse == false &&
        (commerceService == 'chat' || commerceService == 'video') &&
        petId != null &&
        vetId != null &&
        specialtyId != null;
  }

  bool get entitlementExhaustedForRecommendedService {
    final exhausted = serviceCanUse == false ||
        (serviceAccessType != null && remaining != null && remaining! <= 0);
    if (!exhausted) return false;
    if (commerceServiceOverride != null) return true;
    if (serviceCanUse == false &&
        (serviceAccessType == 'chat' || serviceAccessType == 'video')) {
      return true;
    }
    final recommended = payload.recommendedService;
    if (recommended == null) {
      return serviceAccessType == 'chat' || serviceAccessType == 'video';
    }
    final target = recommended == 'scheduled_video' ? 'video' : recommended;
    final accessType =
        serviceAccessType == 'scheduled_video' ? 'video' : serviceAccessType;
    return accessType == null || accessType == target;
  }

  Map<String, dynamic> handoffContext(List<Map<String, dynamic>> messages) => {
        'source': 'ai_chat',
        if (aiEventId != null) 'aiEventId': aiEventId,
        'assistantPayload': payload.handoffMetadata,
        'messages': messages,
        'routing': {
          if (petId != null) 'petId': petId,
          if (specialtyId != null) 'specialtyId': specialtyId,
          if (vetId != null) 'vetId': vetId,
          if (specialtyName != null) 'specialtyName': specialtyName,
          if (vetName != null) 'vetName': vetName,
          if (serviceAccessType != null) 'serviceAccessType': serviceAccessType,
          if (serviceCanUse != null) 'serviceCanUse': serviceCanUse,
          if (serviceAccessReason != null)
            'serviceAccessReason': serviceAccessReason,
          if (remaining != null) 'remaining': remaining,
        },
      };

  _AiChatTurnResult withEntitlement({
    required String serviceType,
    required bool canUse,
    required int remaining,
    String? reason,
    bool upgradeUnavailable = false,
  }) {
    return _AiChatTurnResult(
      payload: payload,
      aiEventId: aiEventId,
      petId: petId,
      specialtyId: specialtyId,
      vetId: vetId,
      specialtyName: specialtyName,
      vetName: vetName,
      serviceAccessType: serviceType,
      serviceCanUse: canUse,
      serviceAccessReason: reason,
      commerceServiceOverride: serviceType == 'video' ? 'video' : 'chat',
      upgradePlan: upgradePlan,
      upgradeUnavailable: upgradeUnavailable,
      remaining: remaining,
    );
  }

  _AiChatTurnResult withUpgradePlan(_ChatSubscriptionPlan plan) {
    return _AiChatTurnResult(
      payload: payload,
      aiEventId: aiEventId,
      petId: petId,
      specialtyId: specialtyId,
      vetId: vetId,
      specialtyName: specialtyName,
      vetName: vetName,
      serviceAccessType: serviceAccessType,
      serviceCanUse: serviceCanUse,
      serviceAccessReason: serviceAccessReason,
      commerceServiceOverride: commerceServiceOverride,
      upgradePlan: plan,
      upgradeUnavailable: false,
      remaining: remaining,
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

  Map<String, dynamic> toJson() => {
        'type': switch (type) {
          _AiMessageBlockType.paragraph => 'paragraph',
          _AiMessageBlockType.numberedList => 'numbered_list',
          _AiMessageBlockType.bulletList => 'bullet_list',
          _AiMessageBlockType.safetyNote => 'safety_note',
        },
        'text': text,
        'items': items,
      };
}

class _AiChatPayload {
  const _AiChatPayload({
    required this.message,
    required this.formatVersion,
    required this.nextStep,
    required this.displayBlocks,
    required this.intakeQuestions,
    required this.urgency,
    required this.recommendedService,
    required this.actionLabel,
    required this.safetyEscalation,
    required this.caseSummary,
    required this.handoffSummary,
    required this.routingRationale,
    required this.commerceRecommendation,
  });

  factory _AiChatPayload.fromJson(Map<String, dynamic> json) {
    final formatVersion = _toInt(json['formatVersion']) ?? 0;
    final intakeQuestions = (_asList(json['intakeQuestions']) ?? const [])
        .map((question) => question?.toString().trim() ?? '')
        .where((question) => question.isNotEmpty)
        .toList(growable: false);
    final displayBlocks = (_asList(json['displayBlocks']) ?? const [])
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .map(_AiMessageBlock.fromJson)
        .whereType<_AiMessageBlock>()
        .toList(growable: false);
    return _AiChatPayload(
      message: json['message']?.toString() ??
          'Te ayudo a encontrar el veterinario adecuado.',
      formatVersion: formatVersion,
      nextStep: json['nextStep']?.toString().toLowerCase() ?? '',
      displayBlocks: displayBlocks,
      intakeQuestions: intakeQuestions,
      urgency: json['urgency']?.toString() ?? 'routine',
      recommendedService: json['recommendedService']?.toString(),
      actionLabel: json['actionLabel']?.toString(),
      safetyEscalation: json['safetyEscalation'] == true,
      caseSummary: json['caseSummary']?.toString(),
      handoffSummary: json['handoffSummary']?.toString(),
      routingRationale: json['routingRationale']?.toString(),
      commerceRecommendation: json['commerceRecommendation']?.toString(),
    );
  }

  final String message;
  final int formatVersion;
  final String nextStep;
  final List<_AiMessageBlock> displayBlocks;
  final List<String> intakeQuestions;
  final String urgency;
  final String? recommendedService;
  final String? actionLabel;
  final bool safetyEscalation;
  final String? caseSummary;
  final String? handoffSummary;
  final String? routingRationale;
  final String? commerceRecommendation;

  bool get hasDisplayBlocks => formatVersion == 1 && displayBlocks.isNotEmpty;

  bool get isInterviewStep {
    if (nextStep == 'interview') return true;
    if (intakeQuestions.isNotEmpty) return true;
    final label = (actionLabel ?? '').toLowerCase();
    return label.contains('responder') ||
        label.contains('pregunta') ||
        label.contains('triaje');
  }

  bool get canShowActions => !isInterviewStep;

  Map<String, dynamic> get historyMetadata => {
        if (nextStep.isNotEmpty) 'nextStep': nextStep,
        'urgency': urgency,
        'intakeQuestions': intakeQuestions,
        if (recommendedService != null)
          'recommendedService': recommendedService,
        if (caseSummary != null) 'caseSummary': caseSummary,
        if (handoffSummary != null) 'handoffSummary': handoffSummary,
        if (routingRationale != null) 'routingRationale': routingRationale,
      };

  Map<String, dynamic> get handoffMetadata => {
        'message': message,
        'formatVersion': formatVersion,
        'nextStep': nextStep,
        'displayBlocks': displayBlocks
            .map((block) => block.toJson())
            .toList(growable: false),
        'intakeQuestions': intakeQuestions,
        'urgency': urgency,
        if (recommendedService != null)
          'recommendedService': recommendedService,
        if (actionLabel != null) 'actionLabel': actionLabel,
        'safetyEscalation': safetyEscalation,
        if (caseSummary != null) 'caseSummary': caseSummary,
        if (handoffSummary != null) 'handoffSummary': handoffSummary,
        if (routingRationale != null) 'routingRationale': routingRationale,
        if (commerceRecommendation != null)
          'commerceRecommendation': commerceRecommendation,
      };
}

class _SubscriptionUpgradeOption {
  const _SubscriptionUpgradeOption(
      {required this.currentPlan,
      required this.targetPlan,
      required this.usage});

  final _ChatSubscriptionPlan? currentPlan;
  final _ChatSubscriptionPlan targetPlan;
  final _ChatSubscriptionUsage usage;
}

class _ChatSubscriptionUsage {
  const _ChatSubscriptionUsage({
    required this.includedChats,
    required this.consumedChats,
    required this.includedVideos,
    required this.consumedVideos,
  });

  factory _ChatSubscriptionUsage.fromJson(Map<String, dynamic> json) {
    return _ChatSubscriptionUsage(
      includedChats: _toInt(json['included_chats']) ?? 0,
      consumedChats: _toInt(json['consumed_chats']) ?? 0,
      includedVideos: _toInt(json['included_videos']) ?? 0,
      consumedVideos: _toInt(json['consumed_videos']) ?? 0,
    );
  }

  final int includedChats;
  final int consumedChats;
  final int includedVideos;
  final int consumedVideos;

  int remainingForPlan(_ChatSubscriptionPlan plan, String service) {
    final included =
        service == 'video' ? plan.includedVideos : plan.includedChats;
    final consumed = service == 'video' ? consumedVideos : consumedChats;
    return math.max(included - consumed, 0);
  }

  int get remainingChats => math.max(includedChats - consumedChats, 0);
  int get remainingVideos => math.max(includedVideos - consumedVideos, 0);

  String get aiSummary =>
      '$consumedChats de $includedChats chats consumidos y $consumedVideos de $includedVideos videollamadas consumidas';
}

class _ChatSubscriptionPlan {
  const _ChatSubscriptionPlan({
    required this.code,
    required this.name,
    required this.monthlyCents,
    required this.currency,
    required this.includedChats,
    required this.includedVideos,
    required this.petsIncludedDefault,
    required this.descriptionMain,
    required this.descriptionIncluded,
  });

  const _ChatSubscriptionPlan.empty()
      : code = '',
        name = '',
        monthlyCents = 0,
        currency = '',
        includedChats = 0,
        includedVideos = 0,
        petsIncludedDefault = 0,
        descriptionMain = '',
        descriptionIncluded = const [];

  factory _ChatSubscriptionPlan.fromJson(Map<String, dynamic> json) {
    final marketing = _marketingMap(json['description_json']);
    final included = marketing['included'];
    final includedList = included is List
        ? included
            .map((item) => item.toString())
            .where((item) => item.trim().isNotEmpty)
            .toList()
        : const <String>[];
    return _ChatSubscriptionPlan(
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      monthlyCents: _toInt(json['price_monthly_cents']) ??
          _toInt(json['price_cents']) ??
          0,
      currency: (json['currency']?.toString() ?? 'MXN').toUpperCase(),
      includedChats: _toInt(json['included_chats']) ?? 0,
      includedVideos: _toInt(json['included_videos']) ?? 0,
      petsIncludedDefault: _toInt(json['pets_included_default']) ?? 1,
      descriptionMain: (marketing['main']?.toString() ??
              json['description']?.toString() ??
              '')
          .trim(),
      descriptionIncluded: includedList,
    );
  }

  final String code;
  final String name;
  final int monthlyCents;
  final String currency;
  final int includedChats;
  final int includedVideos;
  final int petsIncludedDefault;
  final String descriptionMain;
  final List<String> descriptionIncluded;

  String get displayName {
    final key = code.toLowerCase();
    return switch (key) {
      'starter' => 'starter',
      'plus' => 'plus',
      'cuadra' => 'cuadra 5',
      'cuadra-15' => 'cuadra 15',
      'pro-entrenador' => 'entrenador',
      'rancho-trabajo' => 'rancho de trabajo',
      _ => name.isEmpty ? code : name.toLowerCase(),
    };
  }

  int get rank {
    final index = _chatPlanOrder.indexOf(code.toLowerCase());
    return index == -1 ? 999 : index;
  }

  String get monthlyPriceLabel {
    if (monthlyCents <= 0) return 'precio no disponible';
    final amount = monthlyCents % 100 == 0
        ? (monthlyCents ~/ 100).toString()
        : (monthlyCents / 100).toStringAsFixed(2);
    return '$currency $amount al mes';
  }

  String get aiSummary {
    final details = <String>[
      '$displayName ($code)',
      monthlyPriceLabel,
      '$includedChats chats incluidos',
      '$includedVideos videollamadas incluidas',
      '$petsIncludedDefault caballos incluidos',
      if (descriptionMain.isNotEmpty) descriptionMain,
      if (descriptionIncluded.isNotEmpty)
        'Incluye: ${descriptionIncluded.take(3).join('; ')}',
    ];
    return details.join(', ');
  }
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

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

_ChatSubscriptionPlan? _findPlanByCode(
    List<_ChatSubscriptionPlan> plans, String code) {
  final normalized = code.toLowerCase();
  for (final plan in plans) {
    if (plan.code.toLowerCase() == normalized) return plan;
  }
  return null;
}

Map<String, dynamic> _marketingMap(Object? value) {
  final direct = _asMap(value);
  if (direct != null) return direct;
  final raw = value?.toString().trim();
  if (raw == null || raw.isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    return _asMap(decoded) ?? const {};
  } catch (_) {
    return const {};
  }
}

bool _truthy(Object? value) {
  if (value is bool) return value;
  final normalized = value?.toString().toLowerCase();
  return normalized == 'true' || normalized == 't' || normalized == '1';
}

int? _toInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

String _readableAssistantText(String text) {
  var formatted = text.trim().replaceAll('**', '');
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
    RegExp(
        r'([.!?])\s+(?=(Te recomiendo|Para |Si ves|Si empeora|Mientras|Respóndeme|¿))'),
    (match) => '${match[1]}\n\n',
  );
  formatted = formatted.replaceAllMapped(
    RegExp(r'\n{2,}(\d+[.)]\s)'),
    (match) => '\n${match[1]}',
  );
  return formatted;
}

String? _uuidFrom(Object? value) {
  final raw = value?.toString().trim();
  if (raw == null || raw.isEmpty) return null;
  return _ChatScreenState._uuidPattern.hasMatch(raw) ? raw : null;
}

String _errorMessage(Map<String, dynamic> data, int statusCode) {
  final message = data['message'] ?? data['error'];
  if (message is List && message.isNotEmpty) return message.first.toString();
  if (message != null) return message.toString();
  return 'El asistente respondió con error $statusCode.';
}
