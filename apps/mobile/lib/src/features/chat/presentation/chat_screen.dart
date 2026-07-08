import 'dart:math' as math;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

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
final _activeConsultVoiceNoteId = ValueNotifier<String?>(null);
final _activeConsultVideoId = ValueNotifier<String?>(null);

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

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _inputCtrl = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  final _messages = <_ChatMessage>[];
  final _stagedConsultAttachments = <_PendingConsultAttachment>[];
  final _consultUploadCancelTokens = <String, _ConsultUploadCancelToken>{};
  final _imagePicker = ImagePicker();
  final _audioRecorder = AudioRecorder();

  late final String _conversationId;
  RealtimeChannel? _consultMessagesChannel;
  RealtimeChannel? _consultSessionChannel;
  RealtimeChannel? _consultRoomChannel;
  bool _disposing = false;
  Timer? _consultRefreshDebounce;
  Timer? _consultReconnectTimer;
  Timer? _consultReadReceiptDebounce;
  Timer? _consultDraftDebounce;
  Timer? _typingDebounce;
  Timer? _vetTypingClearTimer;
  Timer? _surveyReturnHomeTimer;
  Timer? _recordingTicker;
  bool _isSending = false;
  bool _isReturningHome = false;
  bool _surveyLoading = false;
  bool _consultLoading = false;
  bool _consultClosed = false;
  bool _endingConsult = false;
  bool _recordingVoice = false;
  DateTime? _recordingStartedAt;
  bool _vetOnline = false;
  bool _vetTyping = false;
  bool _vetEnteredAnnounced = false;
  bool _consultOutboxFlushing = false;
  bool _consultCatchUpInFlight = false;
  bool _showConsultDraftRestoredBanner = false;
  int _consultReconnectAttempts = 0;
  DateTime? _lastVetTypingAt;
  String? _unreadConsultMarkerMessageId;
  String? _consultRealtimeStatus;
  String? _inlineConsultSessionId;
  String _consultVetName = 'vet';
  _ActiveSurveyFeedback? _activeSurveyFeedback;

  static const _surveyReturnHomeDelay = Duration(seconds: 5);
  static const _returnHomeFadeDuration = Duration(milliseconds: 260);
  static const _consultSendTimeout = Duration(seconds: 25);

  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    _inputCtrl.addListener(_handleComposerChanged);
    _focusNode.addListener(_handleComposerFocusChanged);
    final initialMessage = widget.initialMessage?.trim();
    final hasInitialMessage =
        initialMessage != null && initialMessage.isNotEmpty;
    final initialAssistantMessage = widget.initialAssistantMessage?.trim();
    final hasInitialAssistantMessage =
        initialAssistantMessage != null && initialAssistantMessage.isNotEmpty;
    final cachedSessionId = _consultSessionId;
    if (_isConsultChatRoute && cachedSessionId != null) {
      unawaited(_restoreConsultDraft(cachedSessionId));
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
    _disposing = true;
    WidgetsBinding.instance.removeObserver(this);
    final sessionId = _uuidOrNull(widget.sessionId);
    if (sessionId != null && !_isConsultChatRoute) {
      _cacheSessionMessages(sessionId);
    }
    _consultRefreshDebounce?.cancel();
    _consultReconnectTimer?.cancel();
    _consultReadReceiptDebounce?.cancel();
    _consultDraftDebounce?.cancel();
    _persistCurrentConsultDraft();
    _sendConsultTyping(false);
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
    _recordingTicker?.cancel();
    _aiChatLog(
        'dispose conversationId=$_conversationId totalMessages=${_messages.length}');
    _inputCtrl.dispose();
    _audioRecorder.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    _surveyReturnHomeTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _sendConsultTyping(false);
      return;
    }
    final sessionId = _consultSessionId;
    if (sessionId == null || _consultClosed) return;
    unawaited(_catchUpConsultMessages(sessionId));
    unawaited(_flushConsultOutbox(sessionId));
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
    _sendConsultTyping(false);
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

  void _traceMessageList(String event, Map<String, Object?> metadata) {
    _aiChatLog('messages.$event $metadata total=${_messages.length}');
  }

  bool get _showsHomeIntro => widget.sessionId == 'ai' && !_isConsultChatRoute;

  String? get _consultSessionId {
    final rawInlineSessionId = _inlineConsultSessionId;
    final inlineSessionId =
        rawInlineSessionId == null ? null : _uuidOrNull(rawInlineSessionId);
    if (inlineSessionId != null) return inlineSessionId;
    final sessionId = _uuidOrNull(widget.sessionId);
    final hasAssistantMessage =
        widget.initialAssistantMessage?.trim().isNotEmpty == true;
    if (sessionId == null ||
        widget.initialSurvey ||
        widget.initialRejoinVideo ||
        hasAssistantMessage) {
      return null;
    }
    return sessionId;
  }

  bool get _isConsultChatRoute => _consultSessionId != null;

  void _sendComposerMessage() {
    final text = _inputCtrl.text.trim();
    final stagedAttachments = List<_PendingConsultAttachment>.unmodifiable(
      _stagedConsultAttachments,
    );
    final hasConsultStagedMedia =
        _isConsultChatRoute && stagedAttachments.isNotEmpty;
    if (text.isEmpty && !hasConsultStagedMedia) {
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
      _sendConsultTyping(false);
      final sessionId = _consultSessionId;
      if (sessionId != null) unawaited(_ConsultDraftStore.clear(sessionId));
      _dismissConsultDraftBanner();
      setState(() => _stagedConsultAttachments.clear());
      unawaited(_sendConsultPayload(
        text: text,
        pendingAttachments: stagedAttachments,
      ));
      return;
    }
    _sendUserMessage(text);
  }

  Future<void> _loadConsultMessages() async {
    final sessionId = _consultSessionId;
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
      final outboxEntries =
          await _ConsultOutboxStore.entriesForSession(sessionId);
      final receipts = _asList(response['receipts']) ?? const [];
      final session = _asMap(response['session']);
      final status = session?['status']?.toString().toLowerCase();
      final vetName = session?['vetName']?.toString().trim();
      if (!mounted) return;
      setState(() {
        final hydratedMessages = _messagesWithReceipts(messages, receipts)
            .map(_mergeExistingConsultMessageMedia)
            .toList(growable: false);
        final serverClientKeys = hydratedMessages
            .map((message) => message.clientKey)
            .whereType<String>()
            .toSet();
        final outboxMessages = outboxEntries
            .where((entry) => !serverClientKeys.contains(entry.clientKey))
            .map((entry) => entry.toMessage())
            .toList(growable: false);
        if (_inlineConsultSessionId == null) {
          _messages
            ..clear()
            ..addAll(hydratedMessages)
            ..addAll(outboxMessages);
        } else {
          _messages.removeWhere((message) => message.streamOrder != null);
          _messages.addAll(hydratedMessages);
          _messages.addAll(outboxMessages);
          _messages.sort(_compareInlineMessages);
        }
        if (vetName != null && vetName.isNotEmpty) {
          _consultVetName = vetName;
        }
        _consultClosed = _isClosedConsultStatus(status);
      });
      _traceMessageList('load', {
        'server': messages.length,
        'outbox': outboxEntries.length,
        'status': status,
      });
      _markVisibleConsultMessagesRead();
      unawaited(_flushConsultOutbox(sessionId));
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
    _consultMessagesChannel = messagesChannel;
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
          _scheduleConsultFullRefresh();
          return;
        }
        if (_hasConsultStreamGap(message)) _scheduleConsultRefresh();
        _upsertConsultMessage(message);
        if (!message.isUser || message.text.trim().isEmpty) {
          _scheduleConsultFullRefresh();
        }
      },
    )
        .subscribe((status, [_]) {
      if (!identical(_consultMessagesChannel, messagesChannel)) return;
      _handleConsultRealtimeStatus(
        sessionId,
        status,
        drivesReconnect: true,
        catchUpOnSubscribe: true,
      );
    });

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
    _consultRoomChannel = channel;
    channel
        .onBroadcast(
          event: 'typing',
          callback: (payload) {
            if (payload['role']?.toString() != 'vet') return;
            final typing = payload['typing'] == true;
            final eventAt = _parseDateTime(payload['at']) ?? DateTime.now();
            if (typing && DateTime.now().difference(eventAt).inSeconds > 8) {
              return;
            }
            if (!mounted) return;
            final wasTyping = _vetTyping;
            if (wasTyping == typing && _lastVetTypingAt == eventAt) return;
            setState(() {
              _lastVetTypingAt = typing ? eventAt : null;
              _vetTyping = typing;
            });
            if (typing && !wasTyping) {
              _announceForAccessibility('El veterinario está escribiendo.');
            }
            _vetTypingClearTimer?.cancel();
            if (typing) {
              _vetTypingClearTimer = Timer(const Duration(seconds: 3), () {
                if (!mounted || _lastVetTypingAt != eventAt) return;
                setState(() {
                  _vetTyping = false;
                  _lastVetTypingAt = null;
                });
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
              _scheduleConsultFullRefresh();
              return;
            }
            final message = _ChatMessage.consultFromJson(record);
            if (message.id.isEmpty) {
              _scheduleConsultFullRefresh();
              return;
            }
            _upsertConsultMessage(message);
            if (!message.isUser || message.text.trim().isEmpty) {
              _scheduleConsultFullRefresh();
            }
          },
        )
        .onPresenceSync((_) => _syncVetPresence(channel))
        .subscribe((status, [_]) {
      if (!identical(_consultRoomChannel, channel)) return;
      if (status == RealtimeSubscribeStatus.subscribed) {
        _handleConsultRealtimeStatus(sessionId, status);
        unawaited(channel.track({
          'role': 'user',
          'userId': userId,
          'onlineAt': DateTime.now().toIso8601String(),
        }));
      } else {
        _handleConsultRealtimeStatus(sessionId, status);
      }
    });
  }

  void _handleConsultRealtimeStatus(
    String sessionId,
    RealtimeSubscribeStatus status, {
    bool drivesReconnect = false,
    bool catchUpOnSubscribe = false,
  }) {
    if (!mounted || _disposing) return;
    if (status == RealtimeSubscribeStatus.subscribed) {
      if (drivesReconnect) {
        _consultReconnectAttempts = 0;
        _consultReconnectTimer?.cancel();
      }
      if (_consultRealtimeStatus != null) {
        if (!mounted || _disposing) return;
        setState(() => _consultRealtimeStatus = null);
      }
      if (catchUpOnSubscribe) unawaited(_catchUpConsultMessages(sessionId));
      return;
    }
    if (!drivesReconnect) return;
    if (!mounted || _disposing) return;
    final nextStatus = switch (status) {
      RealtimeSubscribeStatus.channelError => 'reconectando chat...',
      RealtimeSubscribeStatus.closed => 'chat sin conexión',
      RealtimeSubscribeStatus.timedOut => 'reconectando chat...',
      RealtimeSubscribeStatus.subscribed => null,
    };
    if (_consultRealtimeStatus != nextStatus) {
      setState(() => _consultRealtimeStatus = nextStatus);
    }
    _emitConsultTelemetry('realtime_reconnect', metadata: {
      'status': status.name,
      'reconnectAttempt': _consultReconnectAttempts + 1,
    });
    _scheduleConsultRealtimeRestart(sessionId);
  }

  void _scheduleConsultRealtimeRestart(String sessionId) {
    if (_consultReconnectTimer?.isActive == true) return;
    final delaySeconds = math.min(10, 1 << _consultReconnectAttempts);
    _consultReconnectAttempts = math.min(_consultReconnectAttempts + 1, 4);
    _consultReconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      if (!mounted || _consultClosed) return;
      _stopConsultRealtime();
      _startConsultRealtime(sessionId);
      _startConsultRoomSignals(sessionId);
      unawaited(_catchUpConsultMessages(sessionId));
    });
  }

  void _syncVetPresence(RealtimeChannel channel) {
    final online = channel.presenceState().any((state) => state.presences.any(
          (presence) => presence.payload['role']?.toString() == 'vet',
        ));
    if (mounted) {
      final shouldAnnounce = online && !_vetOnline && !_vetEnteredAnnounced;
      if (!shouldAnnounce && _vetOnline == online) return;
      setState(() {
        if (shouldAnnounce) {
          _messages.add(_ChatMessage.assistant(
            'El veterinario ha entrado al chat.',
            includeInHistory: false,
          ));
          _vetEnteredAnnounced = true;
          _announceForAccessibility('El veterinario ha entrado al chat.');
        }
        _vetOnline = online;
      });
      if (online) _scrollToBottom();
    }
  }

  void _handleComposerChanged() {
    if (!_isConsultChatRoute || _consultClosed || _consultRoomChannel == null) {
      return;
    }
    final sessionId = _consultSessionId;
    if (sessionId != null) {
      _consultDraftDebounce?.cancel();
      _consultDraftDebounce = Timer(const Duration(milliseconds: 400), () {
        unawaited(_ConsultDraftStore.save(sessionId, _inputCtrl.text));
      });
      if (_showConsultDraftRestoredBanner && _inputCtrl.text.trim().isEmpty) {
        _dismissConsultDraftBanner();
      }
    }
    _typingDebounce?.cancel();
    final isTyping = _inputCtrl.text.trim().isNotEmpty;
    _typingDebounce = Timer(const Duration(milliseconds: 300), () {
      _sendConsultTyping(isTyping);
    });
  }

  void _handleComposerFocusChanged() {
    if (!_focusNode.hasFocus) _sendConsultTyping(false);
  }

  Future<void> _restoreConsultDraft(String sessionId) async {
    final draft = await _ConsultDraftStore.read(sessionId);
    if (!mounted || draft == null || draft.trim().isEmpty) return;
    if (_inputCtrl.text.trim().isNotEmpty) return;
    _inputCtrl.text = draft;
    _inputCtrl.selection = TextSelection.collapsed(offset: draft.length);
    setState(() => _showConsultDraftRestoredBanner = true);
    _announceForAccessibility('Borrador restaurado.');
  }

  void _dismissConsultDraftBanner() {
    if (!mounted || !_showConsultDraftRestoredBanner) return;
    setState(() => _showConsultDraftRestoredBanner = false);
  }

  void _persistCurrentConsultDraft() {
    final sessionId = _consultSessionId;
    if (sessionId == null) return;
    unawaited(_ConsultDraftStore.save(sessionId, _inputCtrl.text));
  }

  void _sendConsultTyping(bool typing) {
    final channel = _consultRoomChannel;
    if (channel == null) return;
    _typingDebounce?.cancel();
    unawaited(channel.sendBroadcastMessage(
      event: 'typing',
      payload: {
        'role': 'user',
        'typing': typing,
        'at': DateTime.now().toIso8601String(),
      },
    ));
  }

  void _scheduleConsultRefresh() {
    _traceMessageList('refresh.schedule_catchup', {
      'lastStreamOrder': _lastConsultStreamOrder,
    });
    _consultRefreshDebounce?.cancel();
    _consultRefreshDebounce =
        Timer(const Duration(milliseconds: 350), _refreshConsultMessages);
  }

  void _scheduleConsultFullRefresh() {
    _traceMessageList('refresh.schedule_full', {
      'lastStreamOrder': _lastConsultStreamOrder,
    });
    _consultRefreshDebounce?.cancel();
    _consultRefreshDebounce = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_loadConsultMessages()),
    );
  }

  void _refreshConsultMessages() {
    if (!mounted) return;
    final sessionId = _consultSessionId;
    if (sessionId == null) return;
    unawaited(_catchUpConsultMessages(sessionId));
  }

  int get _lastConsultStreamOrder => _messages
      .map((message) => message.streamOrder ?? 0)
      .fold<int>(0, (max, value) => value > max ? value : max);

  bool _hasConsultStreamGap(_ChatMessage message) {
    final order = message.streamOrder;
    final lastOrder = _lastConsultStreamOrder;
    return order != null && lastOrder > 0 && order > lastOrder + 1;
  }

  Future<void> _catchUpConsultMessages(String sessionId) async {
    if (_consultCatchUpInFlight) return;
    _consultCatchUpInFlight = true;
    final afterStreamOrder = _lastConsultStreamOrder;
    try {
      if (afterStreamOrder <= 0) {
        await _loadConsultMessages();
        return;
      }
      final startedAt = DateTime.now();
      final response = await _getGatewayJson(
        '/sessions/${Uri.encodeComponent(sessionId)}/messages?afterStreamOrder=$afterStreamOrder&limit=100&sort=stream_order.asc',
      );
      final messages = (_asList(response['items']) ?? const [])
          .map(_asMap)
          .whereType<Map<String, dynamic>>()
          .map(_ChatMessage.consultFromJson)
          .toList(growable: false);
      final receipts = _asList(response['receipts']) ?? const [];
      for (final message in _messagesWithReceipts(messages, receipts)) {
        _upsertConsultMessage(message);
      }
      _traceMessageList('catchup', {
        'afterStreamOrder': afterStreamOrder,
        'count': messages.length,
      });
      String? firstIncoming;
      for (final message in messages) {
        if (!message.isUser) {
          firstIncoming = message.id;
          break;
        }
      }
      if (firstIncoming != null && mounted) {
        setState(() => _unreadConsultMarkerMessageId = firstIncoming);
      }
      if (messages.isNotEmpty) _markVisibleConsultMessagesRead();
      unawaited(_flushConsultOutbox(sessionId));
      _emitConsultTelemetry(
        'realtime_catchup',
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
        valueCount: messages.length,
        metadata: {
          'afterStreamOrder': afterStreamOrder,
          'cursor': response['cursor'],
        },
      );
    } catch (error) {
      _aiChatLog('consult catch-up failed: ${error.runtimeType} $error');
    } finally {
      _consultCatchUpInFlight = false;
    }
  }

  void _stopConsultRealtime() {
    final messagesChannel = _consultMessagesChannel;
    if (messagesChannel != null) {
      _consultMessagesChannel = null;
      Supabase.instance.client.removeChannel(messagesChannel);
    }
    final sessionChannel = _consultSessionChannel;
    if (sessionChannel != null) {
      _consultSessionChannel = null;
      Supabase.instance.client.removeChannel(sessionChannel);
    }
    final roomChannel = _consultRoomChannel;
    if (roomChannel != null) {
      _consultRoomChannel = null;
      unawaited(roomChannel.untrack());
      Supabase.instance.client.removeChannel(roomChannel);
    }
  }

  void _enterInlineConsult(String sessionId) {
    _stopConsultRealtime();
    setState(() {
      _inlineConsultSessionId = sessionId;
      _consultClosed = false;
      _consultLoading = false;
      _vetOnline = false;
      _vetTyping = false;
      _vetEnteredAnnounced = false;
      _isSending = false;
      _showConsultDraftRestoredBanner = false;
    });
    unawaited(_restoreConsultDraft(sessionId));
    _startConsultRealtime(sessionId);
    _startConsultRoomSignals(sessionId);
    unawaited(_loadConsultMessages());
    _scrollToBottom();
  }

  void _upsertConsultMessage(_ChatMessage message) {
    if (!mounted) return;
    var inserted = false;
    setState(() {
      final index = _messages.indexWhere((existing) =>
          existing.id == message.id ||
          (message.clientKey != null &&
              existing.clientKey == message.clientKey));
      if (index >= 0) {
        _messages[index] = message.withReceiptFrom(_messages[index]);
      } else {
        _messages.add(message);
        inserted = true;
      }
      _messages.sort(_inlineConsultSessionId == null
          ? _compareConsultMessages
          : _compareInlineMessages);
    });
    _traceMessageList(inserted ? 'upsert.insert' : 'upsert.replace', {
      'id': message.id,
      'clientKey': message.clientKey,
      'streamOrder': message.streamOrder,
      'attachments': message.attachments.length,
    });
    if (message.streamOrder != null && message.clientKey != null) {
      unawaited(_ConsultOutboxStore.remove(message.clientKey!));
    }
    if (!message.isUser) {
      if (inserted) _announceForAccessibility('Nuevo mensaje del veterinario.');
      _markVisibleConsultMessagesRead();
    }
    _scrollToBottom();
  }

  _ChatMessage _mergeExistingConsultMessageMedia(_ChatMessage message) {
    final index = _messages.indexWhere((existing) =>
        existing.id == message.id ||
        (message.clientKey != null && existing.clientKey == message.clientKey));
    if (index < 0) return message;
    return message.withReceiptFrom(_messages[index]);
  }

  int _compareConsultMessages(_ChatMessage a, _ChatMessage b) {
    final aOrder = a.streamOrder;
    final bOrder = b.streamOrder;
    if (aOrder != null && bOrder != null && aOrder != bOrder) {
      return aOrder.compareTo(bOrder);
    }
    return a.id.compareTo(b.id);
  }

  int _compareInlineMessages(_ChatMessage a, _ChatMessage b) {
    final aOrder = a.streamOrder;
    final bOrder = b.streamOrder;
    if (aOrder == null && bOrder == null) return a.id.compareTo(b.id);
    if (aOrder == null) return -1;
    if (bOrder == null) return 1;
    return aOrder.compareTo(bOrder);
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
    var applied = false;
    setState(() {
      final index = _messages.indexWhere((message) => message.id == messageId);
      if (index < 0 || !_messages[index].isUser) return;
      _messages[index] = _messages[index].copyWith(
        deliveredByOther: receipt['delivered_at'] != null,
        readByOther: receipt['read_at'] != null,
      );
      applied = true;
    });
    if (applied) _traceMessageList('receipt.apply', {'messageId': messageId});
  }

  void _markVisibleConsultMessagesRead() {
    final sessionId = _consultSessionId;
    if (sessionId == null) return;
    final lastStreamOrder = _messages
        .where((message) => !message.isUser)
        .map((message) => message.streamOrder ?? 0)
        .fold<int>(0, (max, value) => value > max ? value : max);
    if (lastStreamOrder <= 0) return;
    _consultReadReceiptDebounce?.cancel();
    _consultReadReceiptDebounce = Timer(const Duration(milliseconds: 250), () {
      final startedAt = DateTime.now();
      unawaited(_postGatewayJson(
        '/sessions/${Uri.encodeComponent(sessionId)}/messages/read',
        {'lastStreamOrder': lastStreamOrder},
      ).then((_) {
        _emitConsultTelemetry(
          'read_receipt_sent',
          valueMs: DateTime.now().difference(startedAt).inMilliseconds,
          metadata: {'streamOrder': lastStreamOrder},
        );
      }).catchError((_) {}));
    });
  }

  Future<void> _sendConsultPayload({
    String text = '',
    List<_PendingConsultAttachment> pendingAttachments = const [],
    String? clientKeyOverride,
    bool retrying = false,
    int? attemptsOverride,
  }) async {
    final sessionId = _consultSessionId;
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
    final trimmedText = text.trim();
    if (trimmedText.isEmpty && pendingAttachments.isEmpty) return;
    _sendConsultTyping(false);
    final clientKey = clientKeyOverride ??
        'owner-${DateTime.now().microsecondsSinceEpoch}-${_nextChatMessageId()}';
    final sendStartedAt = DateTime.now();
    _emitConsultTelemetry('send_started', clientKey: clientKey, metadata: {
      'attachmentCount': pendingAttachments.length,
      'retrying': retrying,
    });
    final outboxEntry = _ConsultOutboxEntry(
      sessionId: sessionId,
      clientKey: clientKey,
      text: trimmedText,
      attachments: pendingAttachments,
      status: retrying ? 'retrying' : 'sending',
      attempts: attemptsOverride ?? (retrying ? 1 : 0),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await _ConsultOutboxStore.upsert(outboxEntry);
    final optimisticMessage = _ChatMessage.user(
      trimmedText,
      id: clientKey,
      clientKey: clientKey,
      deliveryState: retrying ? 'retrying' : 'sending',
      includeInHistory: false,
      attachments: pendingAttachments
          .map((attachment) => attachment.toPreviewAttachment())
          .toList(growable: false),
    );
    setState(() {
      final index = _messages.indexWhere((message) =>
          message.id == optimisticMessage.id ||
          message.clientKey == optimisticMessage.clientKey);
      if (index >= 0) {
        _messages[index] = optimisticMessage.withReceiptFrom(_messages[index]);
      } else {
        _messages.add(optimisticMessage);
      }
      _isSending = true;
    });
    _scrollToBottom();

    try {
      final attachmentRefs = <Map<String, String>>[];
      for (final attachment in pendingAttachments) {
        final uploaded = await _uploadConsultAttachment(
          sessionId,
          attachment,
          clientKey: clientKey,
        );
        attachmentRefs.add({'id': uploaded.id});
      }
      final response = await _postGatewayJson(
        '/sessions/${Uri.encodeComponent(sessionId)}/messages',
        {
          'content': trimmedText,
          'clientKey': clientKey,
          if (attachmentRefs.isNotEmpty) 'attachments': attachmentRefs,
        },
      ).timeout(_consultSendTimeout);
      await _ConsultOutboxStore.remove(clientKey);
      final message = _asMap(response['message']);
      _emitConsultTelemetry(
        'send_completed',
        clientKey: clientKey,
        messageId: message?['id']?.toString(),
        durationMs: DateTime.now().difference(sendStartedAt).inMilliseconds,
        metadata: {
          'attachmentCount': attachmentRefs.length,
          'duplicate': response['duplicate'] == true,
          'streamOrder': message?['stream_order'],
        },
      );
      if (message != null) {
        if (mounted) {
          setState(() {
            _messages.removeWhere((candidate) =>
                candidate.id == optimisticMessage.id ||
                candidate.clientKey == clientKey);
          });
          _traceMessageList('optimistic.remove', {'clientKey': clientKey});
        }
        _upsertConsultMessage(_ChatMessage.consultFromJson(message));
      } else {
        await _loadConsultMessages();
      }
      if (mounted) unawaited(HapticFeedback.lightImpact());
    } catch (error) {
      _aiChatLog('consult send failed: ${error.runtimeType} $error');
      if (error is _ConsultUploadCanceledException) {
        await _ConsultOutboxStore.remove(clientKey);
        _consultUploadCancelTokens.remove(clientKey);
        if (mounted) {
          setState(() {
            _messages.removeWhere((candidate) =>
                candidate.id == optimisticMessage.id ||
                candidate.clientKey == clientKey);
          });
          _announceForAccessibility('Carga cancelada.');
        }
        return;
      }
      final errorCode = _telemetryErrorCode(error);
      _emitConsultTelemetry(
        'send_failed',
        clientKey: clientKey,
        durationMs: DateTime.now().difference(sendStartedAt).inMilliseconds,
        errorCode: errorCode,
        metadata: {'attachmentCount': pendingAttachments.length},
      );
      final attempts = outboxEntry.attempts + 1;
      final retryable = _isRetryableConsultErrorCode(errorCode);
      final nextRetryAt = retryable ? _nextConsultRetryAt(attempts) : null;
      await _ConsultOutboxStore.upsert(outboxEntry.copyWith(
        status: retryable ? 'queued' : 'failed',
        attempts: attempts,
        lastError: error.toString(),
        lastErrorCode: errorCode,
        nextRetryAt: nextRetryAt,
        updatedAt: DateTime.now(),
      ));
      if (retryable && nextRetryAt != null) {
        _scheduleConsultOutboxRetry(sessionId, nextRetryAt);
      }
      if (!mounted) return;
      unawaited(HapticFeedback.mediumImpact());
      _announceForAccessibility('No se pudo enviar el mensaje.');
      setState(() {
        final failedMessage = _ChatMessage.user(
          trimmedText,
          id: clientKey,
          clientKey: clientKey,
          deliveryState: 'failed',
          includeInHistory: false,
          attachments: pendingAttachments
              .map((attachment) => attachment.toPreviewAttachment())
              .toList(growable: false),
        );
        final index = _messages.indexWhere((candidate) =>
            candidate.id == optimisticMessage.id ||
            candidate.clientKey == clientKey);
        if (index >= 0) {
          _messages[index] = failedMessage.withReceiptFrom(_messages[index]);
        } else {
          _messages.add(failedMessage);
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('No se pudo enviar.'),
          action: _consultClosed
              ? null
              : SnackBarAction(
                  label: 'Reintentar',
                  onPressed: () => unawaited(_sendConsultPayload(
                    text: trimmedText,
                    pendingAttachments: pendingAttachments,
                    clientKeyOverride: clientKey,
                    retrying: true,
                    attemptsOverride: attempts,
                  )),
                ),
        ),
      );
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _flushConsultOutbox(String sessionId) async {
    if (_consultOutboxFlushing || _isSending || _consultClosed) return;
    _consultOutboxFlushing = true;
    try {
      final entries = await _ConsultOutboxStore.entriesForSession(sessionId);
      for (final entry in entries) {
        if (!mounted || _consultClosed) return;
        if (entry.status == 'failed') continue;
        if (!entry.retryDue) {
          final nextRetryAt = entry.nextRetryAt;
          if (nextRetryAt != null) {
            _scheduleConsultOutboxRetry(sessionId, nextRetryAt);
          }
          continue;
        }
        await _sendConsultPayload(
          text: entry.text,
          pendingAttachments: entry.attachments,
          clientKeyOverride: entry.clientKey,
          retrying: entry.attempts > 0,
          attemptsOverride: entry.attempts,
        );
      }
    } finally {
      _consultOutboxFlushing = false;
    }
  }

  Future<_ConsultAttachment> _uploadConsultAttachment(
    String sessionId,
    _PendingConsultAttachment attachment, {
    required String clientKey,
  }) async {
    final response = await _postGatewayJson(
      '/sessions/${Uri.encodeComponent(sessionId)}/attachments/upload-url',
      attachment.toUploadBody(),
    );
    final attachmentJson = _asMap(response['attachment']);
    final uploadJson = _asMap(response['upload']);
    final bucket = uploadJson?['bucket']?.toString();
    final path = uploadJson?['path']?.toString();
    final token = uploadJson?['token']?.toString();
    if (attachmentJson == null ||
        bucket == null ||
        path == null ||
        token == null) {
      throw const _ChatApiException(
          'No pude preparar el archivo para subirlo.');
    }
    final attachmentId = attachmentJson['id']?.toString();
    final uploadStartedAt = DateTime.now();
    final cancelToken = _consultUploadCancelTokens.putIfAbsent(
        clientKey, _ConsultUploadCancelToken.new);
    _emitConsultTelemetry('upload_started',
        clientKey: clientKey,
        attachmentId: attachmentId,
        valueCount: attachment.byteSize,
        metadata: {'attachmentKind': attachment.kind.name});
    try {
      await _uploadFileToSignedUrlWithProgress(
        bucket: bucket,
        path: path,
        token: token,
        file: File(attachment.path),
        fileName: attachment.fileName,
        contentType: attachment.contentType,
        cancelToken: cancelToken,
        onProgress: (progress) {
          _updateConsultAttachmentUploadProgress(
              clientKey, attachment.path, progress);
          final percent = (progress * 100).round();
          if (percent == 25 ||
              percent == 50 ||
              percent == 75 ||
              percent == 100) {
            _emitConsultTelemetry('upload_progress',
                clientKey: clientKey,
                attachmentId: attachmentId,
                valueCount: percent,
                metadata: {'progressPercent': percent});
          }
        },
      );
      _emitConsultTelemetry('upload_completed',
          clientKey: clientKey,
          attachmentId: attachmentId,
          durationMs: DateTime.now().difference(uploadStartedAt).inMilliseconds,
          valueCount: attachment.byteSize,
          metadata: {'attachmentKind': attachment.kind.name});
      _consultUploadCancelTokens.remove(clientKey);
    } catch (error) {
      if (error is _ConsultUploadCanceledException) rethrow;
      _emitConsultTelemetry('upload_failed',
          clientKey: clientKey,
          attachmentId: attachmentId,
          durationMs: DateTime.now().difference(uploadStartedAt).inMilliseconds,
          valueCount: attachment.byteSize,
          errorCode: _telemetryErrorCode(error),
          metadata: {'attachmentKind': attachment.kind.name});
      _announceForAccessibility('No se pudo subir el archivo.');
      rethrow;
    } finally {
      if (cancelToken.canceled) _consultUploadCancelTokens.remove(clientKey);
    }
    return _ConsultAttachment.fromJson(attachmentJson);
  }

  Future<void> _uploadFileToSignedUrlWithProgress({
    required String bucket,
    required String path,
    required String token,
    required File file,
    required String fileName,
    required String contentType,
    required _ConsultUploadCancelToken cancelToken,
    required ValueChanged<double> onProgress,
  }) async {
    final totalBytes = await file.length();
    if (totalBytes <= 0) {
      throw const _ChatApiException('El archivo está vacío.');
    }
    onProgress(0);
    final boundary = '----cav-${DateTime.now().microsecondsSinceEpoch}';
    final uri =
        _signedStorageUploadUri(bucket: bucket, path: path, token: token);
    final client = HttpClient();
    try {
      if (cancelToken.canceled) throw const _ConsultUploadCanceledException();
      final request = await client.putUrl(uri);
      request.headers.contentType = ContentType(
        'multipart',
        'form-data',
        parameters: {'boundary': boundary},
      );
      request.headers.set('x-upsert', 'false');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final beforeFile = utf8.encode(
        '--$boundary\r\n'
        'content-disposition: form-data; name=""; filename="${_multipartEscape(fileName)}"\r\n'
        'content-type: $contentType\r\n\r\n',
      );
      final afterFile = utf8.encode(
        '\r\n--$boundary\r\n'
        'content-disposition: form-data; name="cacheControl"\r\n\r\n'
        '3600\r\n'
        '--$boundary--\r\n',
      );
      request.contentLength = beforeFile.length + totalBytes + afterFile.length;
      request.add(beforeFile);
      var sentBytes = 0;
      var lastProgress = -1.0;
      await for (final chunk in file.openRead()) {
        if (cancelToken.canceled) {
          client.close(force: true);
          throw const _ConsultUploadCanceledException();
        }
        request.add(chunk);
        sentBytes += chunk.length;
        final progress = (sentBytes / totalBytes).clamp(0.0, 1.0).toDouble();
        if (progress - lastProgress >= 0.01 || progress == 1.0) {
          lastProgress = progress;
          onProgress(progress);
        }
      }
      request.add(afterFile);
      if (cancelToken.canceled) {
        client.close(force: true);
        throw const _ConsultUploadCanceledException();
      }
      final uploadResponse = await request.close();
      final body = await utf8.decoder.bind(uploadResponse).join();
      if (uploadResponse.statusCode < 200 || uploadResponse.statusCode >= 300) {
        throw _ChatApiException(body.isEmpty
            ? 'No pude subir el archivo.'
            : 'No pude subir el archivo: $body');
      }
      onProgress(1);
    } finally {
      client.close(force: true);
    }
  }

  void _cancelConsultUpload(String clientKey) {
    _consultUploadCancelTokens[clientKey]?.cancel();
  }

  Future<void> _retryFailedConsultMessage(String clientKey) async {
    final sessionId = _consultSessionId;
    if (sessionId == null || _consultClosed) return;
    final entries = await _ConsultOutboxStore.entriesForSession(sessionId);
    _ConsultOutboxEntry? entry;
    for (final candidate in entries) {
      if (candidate.clientKey == clientKey) {
        entry = candidate;
        break;
      }
    }
    if (entry == null) return;
    await _sendConsultPayload(
      text: entry.text,
      pendingAttachments: entry.attachments,
      clientKeyOverride: entry.clientKey,
      retrying: true,
      attemptsOverride: entry.attempts,
    );
  }

  bool _isRetryableConsultErrorCode(String code) => !{
        'auth',
        'too_large',
        'unsupported_media',
        'session_closed'
      }.contains(code);

  DateTime _nextConsultRetryAt(int attempts) {
    final seconds = math.min(60, math.pow(2, math.min(attempts, 6)).toInt());
    return DateTime.now().add(
        Duration(seconds: seconds, milliseconds: math.Random().nextInt(750)));
  }

  void _scheduleConsultOutboxRetry(String sessionId, DateTime nextRetryAt) {
    final delay = nextRetryAt.difference(DateTime.now());
    unawaited(Future<void>.delayed(
      delay.isNegative ? Duration.zero : delay,
      () async {
        if (!mounted || _consultClosed) return;
        await _flushConsultOutbox(sessionId);
      },
    ));
  }

  Uri _signedStorageUploadUri({
    required String bucket,
    required String path,
    required String token,
  }) {
    final base = Uri.parse(Environment.supabaseUrl);
    final encodedPath = path
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    final normalizedBasePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
      path:
          '$normalizedBasePath/storage/v1/object/upload/sign/${Uri.encodeComponent(bucket)}/$encodedPath',
      queryParameters: {'token': token},
    );
  }

  String _multipartEscape(String value) => value.replaceAll('"', r'\"');

  void _updateConsultAttachmentUploadProgress(
      String clientKey, String localPath, double progress) {
    if (!mounted) return;
    setState(() {
      final messageIndex = _messages.indexWhere(
        (message) => message.clientKey == clientKey || message.id == clientKey,
      );
      if (messageIndex < 0) return;
      final message = _messages[messageIndex];
      _messages[messageIndex] = message.copyWith(
        attachments: message.attachments
            .map((attachment) =>
                attachment.localPath == localPath || attachment.id == localPath
                    ? attachment.copyWith(uploadProgress: progress)
                    : attachment)
            .toList(growable: false),
      );
    });
  }

  Future<_ConsultAttachment?> _refreshConsultAttachmentDownloadUrl(
      _ConsultAttachment attachment) async {
    final sessionId = _consultSessionId;
    if (sessionId == null) return null;
    final startedAt = DateTime.now();
    try {
      final response = await _getGatewayJson(
        '/sessions/${Uri.encodeComponent(sessionId)}/attachments/${Uri.encodeComponent(attachment.id)}/download-url',
      );
      final attachmentJson = _asMap(response['attachment']);
      if (attachmentJson == null) return null;
      _emitConsultTelemetry(
        'playback_refresh',
        attachmentId: attachment.id,
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
        metadata: {
          'playbackKind': attachment.kind.name,
          'status': 'success',
        },
      );
      return _ConsultAttachment.fromJson(attachmentJson);
    } catch (error) {
      _aiChatLog('attachment refresh failed: ${error.runtimeType} $error');
      _emitConsultTelemetry(
        'playback_refresh',
        attachmentId: attachment.id,
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
        errorCode: _telemetryErrorCode(error),
        metadata: {
          'playbackKind': attachment.kind.name,
          'status': 'failed',
        },
      );
      return null;
    }
  }

  void _emitConsultTelemetry(
    String eventType, {
    String? clientKey,
    String? messageId,
    String? attachmentId,
    int? durationMs,
    int? valueMs,
    int? valueCount,
    String? errorCode,
    Map<String, Object?> metadata = const {},
  }) {
    final sessionId = _consultSessionId;
    if (sessionId == null) return;
    unawaited(_postGatewayJson(
      '/sessions/${Uri.encodeComponent(sessionId)}/telemetry',
      {
        'eventType': eventType,
        if (clientKey != null) 'clientKey': clientKey,
        if (messageId != null) 'messageId': messageId,
        if (attachmentId != null) 'attachmentId': attachmentId,
        if (durationMs != null) 'durationMs': durationMs,
        if (valueMs != null) 'valueMs': valueMs,
        if (valueCount != null) 'valueCount': valueCount,
        if (errorCode != null) 'errorCode': errorCode,
        if (metadata.isNotEmpty) 'metadata': metadata,
      },
    ).catchError((_) => <String, dynamic>{}));
  }

  String _telemetryErrorCode(Object error) {
    final raw = error.toString().toLowerCase();
    if (raw.contains('timeout') || raw.contains('tardó')) return 'timeout';
    if (raw.contains('socket') || raw.contains('conexión')) return 'network';
    if (raw.contains('unauthorized') || raw.contains('sesión')) return 'auth';
    if (raw.contains('too_large') || raw.contains('grande')) return 'too_large';
    if (raw.contains('unsupported')) return 'unsupported_media';
    if (raw.contains('closed') || raw.contains('terminó')) {
      return 'session_closed';
    }
    return error.runtimeType.toString();
  }

  Future<void> _pickConsultMedia() async {
    if (!_canSendConsultMedia) return;
    final choice = await showModalBottomSheet<_ConsultMediaChoice>(
      context: context,
      backgroundColor: const Color(0xFF141417),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  const Icon(Icons.photo_camera_rounded, color: Colors.white),
              title:
                  const Text('cámara', style: TextStyle(color: Colors.white)),
              onTap: () =>
                  Navigator.of(context).pop(_ConsultMediaChoice.camera),
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library_rounded, color: Colors.white),
              title:
                  const Text('imágenes', style: TextStyle(color: Colors.white)),
              onTap: () =>
                  Navigator.of(context).pop(_ConsultMediaChoice.images),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_rounded, color: Colors.white),
              title: const Text('video', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(context).pop(_ConsultMediaChoice.video),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    try {
      if (choice == _ConsultMediaChoice.camera) {
        final file = await _imagePicker.pickImage(
          source: ImageSource.camera,
          imageQuality: 82,
          maxWidth: 1800,
          maxHeight: 1800,
        );
        if (file == null) return;
        _stageConsultAttachments([
          await _pendingAttachmentFromXFile(file, _ConsultAttachmentKind.image)
        ]);
      } else if (choice == _ConsultMediaChoice.images) {
        final files = await _imagePicker.pickMultiImage(
          imageQuality: 82,
          maxWidth: 1800,
          maxHeight: 1800,
          limit: 6,
        );
        if (files.isEmpty) return;
        final attachments = <_PendingConsultAttachment>[];
        for (final file in files.take(6)) {
          attachments.add(await _pendingAttachmentFromXFile(
              file, _ConsultAttachmentKind.image));
        }
        _stageConsultAttachments(attachments);
      } else {
        final file = await _imagePicker.pickVideo(source: ImageSource.gallery);
        if (file == null) return;
        _stageConsultAttachments([
          await _pendingAttachmentFromXFile(file, _ConsultAttachmentKind.video)
        ]);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo adjuntar: $error')),
      );
    }
  }

  void _stageConsultAttachments(List<_PendingConsultAttachment> attachments) {
    if (attachments.isEmpty || !mounted) return;
    final beforeCount = _stagedConsultAttachments.length;
    setState(() {
      final remaining = math.max(0, 6 - _stagedConsultAttachments.length);
      _stagedConsultAttachments.addAll(attachments.take(remaining));
    });
    _announceForAccessibility(
      attachments.length == 1
          ? 'Archivo adjunto listo para enviar.'
          : '${attachments.length} archivos adjuntos listos para enviar.',
    );
    if (beforeCount + attachments.length > 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Puedes adjuntar hasta 6 archivos.')),
      );
    }
  }

  void _removeStagedConsultAttachment(_PendingConsultAttachment attachment) {
    setState(() {
      _stagedConsultAttachments
          .removeWhere((item) => item.path == attachment.path);
    });
    _announceForAccessibility('Archivo adjunto eliminado.');
  }

  Future<_PendingConsultAttachment> _pendingAttachmentFromXFile(
      XFile file, _ConsultAttachmentKind kind) async {
    final preparedFile = await _prepareConsultMediaFile(file, kind);
    final byteSize = await preparedFile.length();
    final contentType = _contentTypeForFile(preparedFile.path, kind);
    _validatePendingAttachment(kind, byteSize, null);
    return _PendingConsultAttachment(
      kind: kind,
      path: preparedFile.path,
      fileName: preparedFile.name,
      contentType: contentType,
      byteSize: byteSize,
    );
  }

  Future<XFile> _prepareConsultMediaFile(
      XFile file, _ConsultAttachmentKind kind) async {
    if (kind == _ConsultAttachmentKind.image) {
      return _compressConsultImage(file);
    }
    if (kind == _ConsultAttachmentKind.video) {
      return _compressConsultVideo(file);
    }
    return file;
  }

  Future<XFile> _compressConsultImage(XFile file) async {
    try {
      final originalSize = await file.length();
      final dir = await getTemporaryDirectory();
      final targetPath =
          '${dir.path}/consult-image-${DateTime.now().microsecondsSinceEpoch}.jpg';
      final compressed = await FlutterImageCompress.compressAndGetFile(
        file.path,
        targetPath,
        quality: 82,
        minWidth: 1800,
        minHeight: 1800,
        format: CompressFormat.jpeg,
      );
      if (compressed == null) return file;
      final compressedSize = await compressed.length();
      return compressedSize > 0 && compressedSize < originalSize
          ? compressed
          : file;
    } catch (error) {
      _aiChatLog('image compression skipped: ${error.runtimeType} $error');
      return file;
    }
  }

  Future<XFile> _compressConsultVideo(XFile file) async {
    try {
      final originalSize = await file.length();
      final mediaInfo = await VideoCompress.compressVideo(
        file.path,
        quality: VideoQuality.MediumQuality,
        deleteOrigin: false,
        includeAudio: true,
      );
      final compressedPath = mediaInfo?.path;
      if (compressedPath == null || compressedPath.isEmpty) return file;
      final compressed = XFile(compressedPath);
      final compressedSize = await compressed.length();
      return compressedSize > 0 && compressedSize < originalSize
          ? compressed
          : file;
    } catch (error) {
      _aiChatLog('video compression skipped: ${error.runtimeType} $error');
      return file;
    }
  }

  bool get _canSendConsultMedia =>
      _consultSessionId != null &&
      !_isSending &&
      !_consultClosed &&
      !_endingConsult;

  Future<void> _startVoiceRecording() async {
    if (!_canSendConsultMedia || _recordingVoice) return;
    try {
      if (!await _audioRecorder.hasPermission()) {
        throw const _ChatApiException(
            'Activa el micrófono para enviar notas de voz.');
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/consult-voice-${DateTime.now().microsecondsSinceEpoch}.m4a';
      await _audioRecorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      if (!mounted) return;
      setState(() {
        _recordingVoice = true;
        _recordingStartedAt = DateTime.now();
      });
      _recordingTicker?.cancel();
      _recordingTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted && _recordingVoice) setState(() {});
      });
      unawaited(HapticFeedback.mediumImpact());
      _announceForAccessibility('Grabando nota de voz.');
    } catch (error) {
      if (!mounted) return;
      _announceForAccessibility('No se pudo iniciar la grabación.');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No pude grabar: $error')),
      );
    }
  }

  Future<void> _stopVoiceRecording({bool send = true}) async {
    if (!_recordingVoice) return;
    final startedAt = _recordingStartedAt;
    setState(() {
      _recordingVoice = false;
      _recordingStartedAt = null;
    });
    _recordingTicker?.cancel();
    _recordingTicker = null;
    unawaited(HapticFeedback.lightImpact());
    final path = await _audioRecorder.stop();
    if (!send || path == null) return;
    final durationMs = startedAt == null
        ? null
        : DateTime.now().difference(startedAt).inMilliseconds;
    if (durationMs != null && durationMs < 650) return;
    try {
      final file = File(path);
      final byteSize = await file.length();
      _validatePendingAttachment(
          _ConsultAttachmentKind.voice, byteSize, durationMs);
      _stageConsultAttachments([
        _PendingConsultAttachment(
          kind: _ConsultAttachmentKind.voice,
          path: path,
          fileName: path.split('/').last,
          contentType: 'audio/mp4',
          byteSize: byteSize,
          durationMs: durationMs,
        ),
      ]);
      _announceForAccessibility('Nota de voz lista para enviar.');
    } catch (error) {
      if (!mounted) return;
      _announceForAccessibility('No se pudo adjuntar la nota de voz.');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo enviar la nota de voz: $error')),
      );
    }
  }

  void _announceForAccessibility(String message) {
    if (!mounted) return;
    unawaited(SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    ));
  }

  Future<void> _endConsultFromOwner() async {
    final sessionId = _consultSessionId;
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
    final sessionId = _consultSessionId;
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
          'Tu consulta ha terminado, te agradecemos tu preferencia. ¿Quieres calificar tu consulta ahora?',
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
                : '¡Gracias!',
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
        'completeStartedSession chat session active sessionId=$sessionId; staying inline');
    if (!mounted) return;
    _enterInlineConsult(sessionId);
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
    final bottomListPadding = bottomInset +
        (_stagedConsultAttachments.isNotEmpty || _recordingVoice ? 178 : 126);
    final showHomeIntro = _showsHomeIntro;
    final messageList = ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(
        18,
        topChromeHeight,
        18,
        bottomListPadding,
      ),
      itemCount: (showHomeIntro ? 1 : 0) + _messages.length,
      itemBuilder: (context, index) {
        final introCount = showHomeIntro ? 1 : 0;
        if (showHomeIntro && index == 0) {
          return _HomeChatIntro(displayName: _homeDisplayName);
        }
        final messageIndex = index - introCount;
        final message = _messages[messageIndex];
        final nextMessage = messageIndex < _messages.length - 1
            ? _messages[messageIndex + 1]
            : null;
        final showMessageLog = nextMessage == null ||
            nextMessage.role != message.role ||
            message.deliveryState == 'failed';
        final isFirstUserMessage = message.isUser &&
            !_messages.take(messageIndex).any((message) => message.isUser);
        final userTurnsBeforeOrAtMessage = _messages
            .take(messageIndex + 1)
            .where((message) => message.isUser)
            .length;
        return Column(
          key: ValueKey('thread-${message.id}'),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_unreadConsultMarkerMessageId == message.id)
              const _UnreadMessagesMarker(),
            _AnimatedMessageEntry(
              key: ValueKey(message.id),
              isUser: message.isUser,
              isFirstUserMessage: isFirstUserMessage,
              child: _MessageBubble(
                message: message,
                vetName: _consultVetName,
                sending: _isSending,
                showMessageLog: showMessageLog,
                canShowActions: userTurnsBeforeOrAtMessage >= 2,
                onServiceSelected: _activateService,
                onOneOffPurchaseSelected: _purchaseSingleSession,
                onUpgradeSelected: _openSubscriptionUpgrade,
                onPlanUpgradeConfirmed: _confirmSubscriptionUpgrade,
                onRejoinVideo: _openVideoFromChat,
                onSurveyAction: _handleSurveyAction,
                onRefreshAttachment: _refreshConsultAttachmentDownloadUrl,
                onCancelUpload: _cancelConsultUpload,
                onRetryMessage: (clientKey) =>
                    unawaited(_retryFailedConsultMessage(clientKey)),
              ),
            ),
          ],
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
        if (_showConsultDraftRestoredBanner)
          Positioned(
            left: 18,
            right: 18,
            bottom: bottomInset + 88,
            child: _DraftRestoredBanner(onDismiss: _dismissConsultDraftBanner),
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
                  ? _consultRealtimeStatus ??
                      (_vetTyping
                          ? 'veterinario escribiendo...'
                          : _vetOnline
                              ? 'veterinario en línea'
                              : 'consulta activa')
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
            mediaEnabled: _canSendConsultMedia,
            showMediaControls: _isConsultChatRoute,
            recording: _recordingVoice,
            recordingStartedAt: _recordingStartedAt,
            stagedAttachments: _stagedConsultAttachments,
            includeBottomInset: true,
            onSend: _sendComposerMessage,
            onPickMedia: _pickConsultMedia,
            onRemoveAttachment: _removeStagedConsultAttachment,
            onMicStart: _startVoiceRecording,
            onMicStop: _stopVoiceRecording,
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

class _UnreadMessagesMarker extends StatelessWidget {
  const _UnreadMessagesMarker();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(child: Divider(color: Colors.white.withValues(alpha: 0.18))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              'Nuevos',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.72),
                fontSize: 11,
                fontFamily: 'ABCDiatype',
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(child: Divider(color: Colors.white.withValues(alpha: 0.18))),
        ],
      ),
    );
  }
}

class _DraftRestoredBanner extends StatelessWidget {
  const _DraftRestoredBanner({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              const Icon(Icons.restore_rounded, color: Colors.white, size: 17),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Borrador restaurado',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.86),
                    fontSize: 12,
                    fontFamily: 'ABCDiatype',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Ocultar aviso de borrador',
                onPressed: onDismiss,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  fixedSize: const Size(36, 36),
                  padding: EdgeInsets.zero,
                ),
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 18),
              ),
            ],
          ),
        ),
      ),
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
          Semantics(
            button: true,
            label: 'Volver al inicio',
            child: Tooltip(
              message: 'Volver',
              child: GestureDetector(
                onTap: onBack,
                behavior: HitTestBehavior.opaque,
                child: const SizedBox(
                  width: 44,
                  height: 44,
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
            Semantics(
              button: true,
              enabled: !ending,
              label: ending ? 'Cerrando consulta' : 'Cerrar consulta',
              child: TextButton(
                onPressed: ending ? null : onEnd,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  disabledForegroundColor: Colors.white.withValues(alpha: 0.35),
                  minimumSize: const Size(44, 44),
                ),
                child: Text(ending ? 'cerrando...' : 'cerrar'),
              ),
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
    required this.vetName,
    required this.sending,
    required this.showMessageLog,
    required this.canShowActions,
    required this.onServiceSelected,
    required this.onOneOffPurchaseSelected,
    required this.onUpgradeSelected,
    required this.onPlanUpgradeConfirmed,
    required this.onRejoinVideo,
    required this.onSurveyAction,
    required this.onCancelUpload,
    required this.onRetryMessage,
    this.onRefreshAttachment,
  });

  final _ChatMessage message;
  final String vetName;
  final bool sending;
  final bool showMessageLog;
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
  final ValueChanged<String> onCancelUpload;
  final ValueChanged<String> onRetryMessage;
  final Future<_ConsultAttachment?> Function(_ConsultAttachment attachment)?
      onRefreshAttachment;

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final bubbleColor = isUser ? const Color(0xFF242426) : Colors.black;
    const textColor = Colors.white;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final widthFactor = isUser ? 0.66 : 0.72;
    final fixedCap = isUser ? 350.0 : 380.0;
    final maxBubbleWidth = math.min(viewportWidth * widthFactor, fixedCap);
    final trimmedText = message.text.trim();
    final isVoiceOnly = trimmedText.isEmpty &&
        message.attachments.length == 1 &&
        message.attachments.first.kind == _ConsultAttachmentKind.voice;
    final isSingleImageOnly = trimmedText.isEmpty &&
        message.attachments.length == 1 &&
        message.attachments.first.kind == _ConsultAttachmentKind.image;
    final isEmptyPlaceholder = trimmedText.isEmpty && !message.hasAttachments;
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
              if (!isEmptyPlaceholder)
                if (isVoiceOnly || isSingleImageOnly)
                  _ConsultAttachmentStrip(
                    attachments: message.attachments,
                    clientKey: message.clientKey,
                    onCancelUpload: onCancelUpload,
                    onRefreshAttachment: onRefreshAttachment,
                    flushSingleImage: isSingleImageOnly,
                  )
                else
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 13),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (trimmedText.isNotEmpty)
                            isUser
                                ? Text(message.text, style: messageTextStyle)
                                : _AssistantMessageContent(
                                    text: message.text,
                                    payload: message.result?.payload,
                                    style: messageTextStyle,
                                  ),
                          if (message.hasAttachments) ...[
                            if (trimmedText.isNotEmpty)
                              const SizedBox(height: 10),
                            _ConsultAttachmentStrip(
                              attachments: message.attachments,
                              clientKey: message.clientKey,
                              onCancelUpload: onCancelUpload,
                              onRefreshAttachment: onRefreshAttachment,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              if (showMessageLog &&
                  message.consultLabel(vetName: vetName) != null) ...[
                const SizedBox(height: 4),
                Text(
                  message.consultLabel(vetName: vetName)!,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.38),
                    fontSize: 10,
                    fontFamily: 'ABCDiatype',
                  ),
                ),
              ],
              if (isUser &&
                  message.deliveryState == 'failed' &&
                  message.clientKey != null) ...[
                const SizedBox(height: 5),
                TextButton.icon(
                  onPressed: () => onRetryMessage(message.clientKey!),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    minimumSize: const Size(44, 36),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Reintentar'),
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

class _ConsultAttachmentStrip extends StatefulWidget {
  const _ConsultAttachmentStrip({
    required this.attachments,
    required this.clientKey,
    required this.onCancelUpload,
    this.flushSingleImage = false,
    this.onRefreshAttachment,
  });

  final List<_ConsultAttachment> attachments;
  final String? clientKey;
  final ValueChanged<String> onCancelUpload;
  final bool flushSingleImage;
  final Future<_ConsultAttachment?> Function(_ConsultAttachment attachment)?
      onRefreshAttachment;

  @override
  State<_ConsultAttachmentStrip> createState() =>
      _ConsultAttachmentStripState();
}

class _ConsultAttachmentStripState extends State<_ConsultAttachmentStrip> {
  final _prewarmedImageUrls = <String>{};
  final _readyImageUrls = <String>{};
  Timer? _revealTimer;
  bool _readyToReveal = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncImageReadiness();
  }

  @override
  void didUpdateWidget(covariant _ConsultAttachmentStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncImageReadiness();
  }

  @override
  void dispose() {
    _revealTimer?.cancel();
    super.dispose();
  }

  void _syncImageReadiness() {
    final networkImageUrls = widget.attachments
        .where((attachment) =>
            attachment.kind == _ConsultAttachmentKind.image &&
            attachment.localPath == null)
        .map(_consultDisplayImageUrl)
        .whereType<String>()
        .where((url) => url.trim().isNotEmpty)
        .toList(growable: false);
    final shouldCoordinate = networkImageUrls.length > 1;
    if (!shouldCoordinate) {
      _revealTimer?.cancel();
      if (!_readyToReveal) setState(() => _readyToReveal = true);
    }
    for (final url in networkImageUrls) {
      if (!_prewarmedImageUrls.add(url)) continue;
      unawaited(precacheImage(NetworkImage(url), context).then((_) {
        _readyImageUrls.add(url);
        if (mounted &&
            networkImageUrls.every(_readyImageUrls.contains) &&
            !_readyToReveal) {
          setState(() => _readyToReveal = true);
        }
      }).catchError((_) {
        _readyImageUrls.add(url);
        if (mounted &&
            networkImageUrls.every(_readyImageUrls.contains) &&
            !_readyToReveal) {
          setState(() => _readyToReveal = true);
        }
      }));
    }
    if (!shouldCoordinate) return;
    if (networkImageUrls.every(_readyImageUrls.contains)) {
      if (!_readyToReveal) setState(() => _readyToReveal = true);
      return;
    }
    if (_readyToReveal) setState(() => _readyToReveal = false);
    _revealTimer?.cancel();
    _revealTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _readyToReveal = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _readyToReveal ? 1 : 0,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: widget.attachments
            .map((attachment) => Padding(
                  padding: EdgeInsets.only(
                      bottom: widget.flushSingleImage &&
                              widget.attachments.length == 1
                          ? 0
                          : 6),
                  child: _ConsultAttachmentPreview(
                    attachment: attachment,
                    clientKey: widget.clientKey,
                    onCancelUpload: widget.onCancelUpload,
                    onRefreshAttachment: widget.onRefreshAttachment,
                    flushImage: widget.flushSingleImage &&
                        widget.attachments.length == 1,
                  ),
                ))
            .toList(growable: false),
      ),
    );
  }
}

String? _consultDisplayImageUrl(_ConsultAttachment attachment) {
  return _nonEmpty(attachment.thumbnailUrl) ??
      _nonEmpty(attachment.downloadUrl);
}

class _ConsultAttachmentPreview extends StatelessWidget {
  const _ConsultAttachmentPreview({
    required this.attachment,
    required this.clientKey,
    required this.onCancelUpload,
    this.flushImage = false,
    this.onRefreshAttachment,
  });

  final _ConsultAttachment attachment;
  final String? clientKey;
  final ValueChanged<String> onCancelUpload;
  final bool flushImage;
  final Future<_ConsultAttachment?> Function(_ConsultAttachment attachment)?
      onRefreshAttachment;

  Future<void> _openImage(BuildContext context) async {
    final source = attachment.localPath ??
        (onRefreshAttachment == null
            ? attachment.downloadUrl
            : (await onRefreshAttachment!(attachment))?.downloadUrl ??
                attachment.downloadUrl);
    if (!context.mounted || source == null || source.isEmpty) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (context) {
        final image = attachment.localPath != null
            ? Image.file(File(source), fit: BoxFit.contain)
            : Image.network(source, fit: BoxFit.contain);
        return GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: DecoratedBox(
            decoration: const BoxDecoration(color: Colors.black),
            child: SafeArea(
              child: Stack(
                children: [
                  Center(
                    child: InteractiveViewer(
                      minScale: 1,
                      maxScale: 4,
                      child: image,
                    ),
                  ),
                  Positioned(
                    top: 12,
                    right: 12,
                    child: IconButton.filled(
                      tooltip: 'Cerrar imagen',
                      onPressed: () => Navigator.of(context).pop(),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.12),
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayUrl = _consultDisplayImageUrl(attachment);
    final localPath = attachment.localPath;
    final label = switch (attachment.kind) {
      _ConsultAttachmentKind.image => 'Imagen',
      _ConsultAttachmentKind.video => 'Video',
      _ConsultAttachmentKind.voice => 'Nota de voz',
    };
    if (attachment.kind == _ConsultAttachmentKind.image &&
        (displayUrl != null || localPath != null)) {
      final image = localPath != null
          ? Image.file(File(localPath),
              fit: BoxFit.cover, gaplessPlayback: true)
          : Image.network(displayUrl!,
              fit: BoxFit.cover, gaplessPlayback: true);
      return GestureDetector(
        onTap: () => _openImage(context),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: flushImage ? double.infinity : 220,
            height: flushImage ? 210 : 160,
            child: Stack(
              fit: StackFit.expand,
              children: [
                image,
                if (attachment.isUploading)
                  _AttachmentUploadOverlay(
                    attachment: attachment,
                    onCancel: clientKey == null
                        ? null
                        : () => onCancelUpload(clientKey!),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (attachment.kind == _ConsultAttachmentKind.voice) {
      return _ConsultVoiceNoteBubble(
        attachment: attachment,
        onRefreshAttachment: onRefreshAttachment,
      );
    }
    if (attachment.kind == _ConsultAttachmentKind.video) {
      return _ConsultVideoBubble(
        attachment: attachment,
        onRefreshAttachment: onRefreshAttachment,
      );
    }
    final bubble = Container(
      constraints: const BoxConstraints(minWidth: 180),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            attachment.kind == _ConsultAttachmentKind.image
                ? Icons.image_rounded
                : attachment.kind == _ConsultAttachmentKind.voice
                    ? Icons.mic_rounded
                    : Icons.play_arrow_rounded,
            color: Colors.white,
            size: 19,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              attachment.isUploading
                  ? _uploadProgressText(attachment)
                  : _attachmentLabel(label, attachment),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
    return attachment.kind == _ConsultAttachmentKind.image
        ? GestureDetector(onTap: () => _openImage(context), child: bubble)
        : bubble;
  }
}

class _AttachmentUploadOverlay extends StatelessWidget {
  const _AttachmentUploadOverlay({required this.attachment, this.onCancel});

  final _ConsultAttachment attachment;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final progress = attachment.uploadProgress.clamp(0.0, 1.0).toDouble();
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.42)),
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        _TinyUploadSpinner(progress: progress),
                        const SizedBox(width: 7),
                        Text(
                          _uploadProgressText(attachment),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onCancel != null)
                    IconButton(
                      tooltip: 'Cancelar carga',
                      onPressed: onCancel,
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        fixedSize: const Size(36, 36),
                        padding: EdgeInsets.zero,
                      ),
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.white, size: 18),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TinyUploadSpinner extends StatelessWidget {
  const _TinyUploadSpinner({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 12,
      height: 12,
      child: CircularProgressIndicator(
        value: progress <= 0 ? null : progress,
        strokeWidth: 1.6,
        color: Colors.white,
        backgroundColor: Colors.white.withValues(alpha: 0.18),
      ),
    );
  }
}

class _ConsultVoiceNoteBubble extends StatefulWidget {
  const _ConsultVoiceNoteBubble({
    required this.attachment,
    this.onRefreshAttachment,
  });

  final _ConsultAttachment attachment;
  final Future<_ConsultAttachment?> Function(_ConsultAttachment attachment)?
      onRefreshAttachment;

  @override
  State<_ConsultVoiceNoteBubble> createState() =>
      _ConsultVoiceNoteBubbleState();
}

class _ConsultVoiceNoteBubbleState extends State<_ConsultVoiceNoteBubble> {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlayerState>? _stateSub;
  bool _loading = false;
  bool _loaded = false;
  bool _failed = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _downloadUrl;

  @override
  void initState() {
    super.initState();
    _downloadUrl = widget.attachment.downloadUrl;
    _activeConsultVoiceNoteId.addListener(_handleActiveVoiceChanged);
    _positionSub = _player.positionStream.listen((position) {
      if (!mounted) return;
      setState(() => _position = position);
    });
    _durationSub = _player.durationStream.listen((duration) {
      if (!mounted || duration == null) return;
      setState(() => _duration = duration);
    });
    _stateSub = _player.playerStateStream.listen((state) {
      if (!mounted) return;
      if (state.processingState == ProcessingState.completed) {
        if (_activeConsultVoiceNoteId.value == widget.attachment.id) {
          _activeConsultVoiceNoteId.value = null;
        }
        unawaited(_player.seek(Duration.zero));
      }
      setState(() {
        _playing =
            state.playing && state.processingState != ProcessingState.completed;
      });
    });
  }

  @override
  void didUpdateWidget(covariant _ConsultVoiceNoteBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.id != widget.attachment.id ||
        oldWidget.attachment.downloadUrl != widget.attachment.downloadUrl ||
        oldWidget.attachment.localPath != widget.attachment.localPath) {
      _downloadUrl = widget.attachment.downloadUrl;
      _loaded = false;
      _failed = false;
      _position = Duration.zero;
      _duration = Duration.zero;
      unawaited(_player.stop());
    }
  }

  @override
  void dispose() {
    _activeConsultVoiceNoteId.removeListener(_handleActiveVoiceChanged);
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _handleActiveVoiceChanged() {
    if (_activeConsultVoiceNoteId.value != widget.attachment.id &&
        _player.playing) {
      unawaited(_player.pause());
    }
  }

  Future<void> _togglePlayback() async {
    if (_loading || widget.attachment.isUploading) return;
    if (_player.playing) {
      await _player.pause();
      return;
    }
    final source = widget.attachment.localPath ?? _downloadUrl;
    if (source == null || source.isEmpty) return;
    _activeConsultVoiceNoteId.value = widget.attachment.id;
    if (!_loaded || _failed) {
      setState(() {
        _loading = true;
        _failed = false;
      });
      try {
        if (widget.attachment.localPath != null) {
          await _player.setFilePath(widget.attachment.localPath!);
        } else {
          await _player.setUrl(_downloadUrl!);
        }
        if (!mounted) return;
        setState(() => _loaded = true);
      } catch (error) {
        if (widget.attachment.localPath == null &&
            await _refreshDownloadUrl()) {
          try {
            await _player.setUrl(_downloadUrl!);
            if (!mounted) return;
            setState(() => _loaded = true);
          } catch (_) {
            if (!mounted) return;
            setState(() => _failed = true);
            return;
          }
        } else {
          if (!mounted) return;
          setState(() => _failed = true);
          return;
        }
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    }
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
    }
    await _player.play();
  }

  Future<bool> _refreshDownloadUrl() async {
    final refresh = widget.onRefreshAttachment;
    if (refresh == null) return false;
    final refreshed = await refresh(widget.attachment);
    final refreshedUrl = refreshed?.downloadUrl;
    if (refreshedUrl == null || refreshedUrl.isEmpty) return false;
    _downloadUrl = refreshedUrl;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final progress = _duration.inMilliseconds <= 0
        ? 0.0
        : (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
    final displayDuration = _duration.inMilliseconds > 0
        ? _duration
        : Duration(milliseconds: widget.attachment.durationMs ?? 0);
    final durationText = _playing && _position.inMilliseconds > 0
        ? _formatVoiceDuration(_position)
        : _formatVoiceDuration(displayDuration);
    final icon = _loading
        ? null
        : _failed
            ? Icons.refresh_rounded
            : _playing
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded;
    final playLabel = _failed
        ? 'Reintentar nota de voz'
        : _playing
            ? 'Pausar nota de voz'
            : 'Reproducir nota de voz';

    return Container(
      width: 232,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Semantics(
            button: true,
            enabled: !_loading && !widget.attachment.isUploading,
            label: playLabel,
            child: Tooltip(
              message: playLabel,
              child: GestureDetector(
                onTap: _togglePlayback,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: _loading
                          ? const Padding(
                              padding: EdgeInsets.all(9),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : Icon(icon, color: Colors.black, size: 21),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _VoiceWaveform(id: widget.attachment.id, progress: progress),
                const SizedBox(height: 4),
                Text(
                  _failed
                      ? 'Toca para reintentar'
                      : widget.attachment.isUploading
                          ? _uploadProgressText(widget.attachment)
                          : durationText,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    height: 1,
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

class _ConsultVideoBubble extends StatefulWidget {
  const _ConsultVideoBubble({
    required this.attachment,
    this.onRefreshAttachment,
  });

  final _ConsultAttachment attachment;
  final Future<_ConsultAttachment?> Function(_ConsultAttachment attachment)?
      onRefreshAttachment;

  @override
  State<_ConsultVideoBubble> createState() => _ConsultVideoBubbleState();
}

class _ConsultVideoBubbleState extends State<_ConsultVideoBubble> {
  VideoPlayerController? _controller;
  bool _loading = false;
  bool _failed = false;
  String? _downloadUrl;

  @override
  void initState() {
    super.initState();
    _downloadUrl = widget.attachment.downloadUrl;
    _activeConsultVideoId.addListener(_handleActiveVideoChanged);
  }

  @override
  void didUpdateWidget(covariant _ConsultVideoBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.id != widget.attachment.id ||
        oldWidget.attachment.downloadUrl != widget.attachment.downloadUrl ||
        oldWidget.attachment.localPath != widget.attachment.localPath) {
      _downloadUrl = widget.attachment.downloadUrl;
      _failed = false;
      _disposeController();
    }
  }

  @override
  void dispose() {
    _activeConsultVideoId.removeListener(_handleActiveVideoChanged);
    if (_activeConsultVideoId.value == widget.attachment.id) {
      _activeConsultVideoId.value = null;
    }
    _disposeController();
    super.dispose();
  }

  void _handleActiveVideoChanged() {
    if (_activeConsultVideoId.value != widget.attachment.id &&
        _controller?.value.isPlaying == true) {
      unawaited(_controller?.pause());
    }
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;
    if (!value.isPlaying &&
        value.duration > Duration.zero &&
        value.position >= value.duration &&
        _activeConsultVideoId.value == widget.attachment.id) {
      _activeConsultVideoId.value = null;
    }
    setState(() {});
  }

  void _disposeController() {
    final controller = _controller;
    if (controller == null) return;
    controller.removeListener(_handleControllerChanged);
    _controller = null;
    unawaited(controller.dispose());
  }

  Future<void> _togglePlayback() async {
    if (_loading ||
        (widget.attachment.isUploading &&
            widget.attachment.localPath == null)) {
      return;
    }
    var controller = _controller;
    if (controller == null || !controller.value.isInitialized || _failed) {
      await _initializeVideo();
      controller = _controller;
      if (controller == null || !controller.value.isInitialized) return;
    }
    if (controller.value.isPlaying) {
      await controller.pause();
      if (_activeConsultVideoId.value == widget.attachment.id) {
        _activeConsultVideoId.value = null;
      }
      return;
    }
    _activeConsultVideoId.value = widget.attachment.id;
    await controller.play();
  }

  Future<void> _initializeVideo() async {
    final source = widget.attachment.localPath ?? _downloadUrl;
    if (source == null || source.isEmpty) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      await _openVideoSource(source);
    } catch (_) {
      if (widget.attachment.localPath == null && await _refreshDownloadUrl()) {
        try {
          await _openVideoSource(_downloadUrl!);
        } catch (_) {
          if (!mounted) return;
          setState(() => _failed = true);
        }
      } else {
        if (!mounted) return;
        setState(() => _failed = true);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openVideoSource(String source) async {
    final controller = widget.attachment.localPath != null
        ? VideoPlayerController.file(File(widget.attachment.localPath!))
        : VideoPlayerController.networkUrl(Uri.parse(source));
    await controller.initialize();
    await controller.setLooping(false);
    controller.addListener(_handleControllerChanged);
    _disposeController();
    if (!mounted) {
      unawaited(controller.dispose());
      return;
    }
    setState(() {
      _controller = controller;
      _failed = false;
    });
  }

  Future<bool> _refreshDownloadUrl() async {
    final refresh = widget.onRefreshAttachment;
    if (refresh == null) return false;
    final refreshed = await refresh(widget.attachment);
    final refreshedUrl = refreshed?.downloadUrl;
    if (refreshedUrl == null || refreshedUrl.isEmpty) return false;
    _downloadUrl = refreshedUrl;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final value = controller?.value;
    final initialized = value?.isInitialized == true;
    final rawAspect = initialized ? value!.aspectRatio : 16 / 9;
    final aspectRatio = rawAspect.isFinite && rawAspect > 0
        ? rawAspect.clamp(0.75, 1.78).toDouble()
        : 16 / 9;
    final position = initialized ? value!.position : Duration.zero;
    final duration = initialized ? value!.duration : Duration.zero;
    final progress = duration.inMilliseconds <= 0
        ? 0.0
        : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    final playing = value?.isPlaying == true;
    final overlayVisible = _loading || _failed || !playing;
    final icon = _loading
        ? null
        : _failed
            ? Icons.refresh_rounded
            : playing
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded;
    final label = _failed
        ? 'Toca para reintentar'
        : widget.attachment.isUploading
            ? _uploadProgressText(widget.attachment)
            : duration.inMilliseconds > 0
                ? '${_formatVoiceDuration(position)} / ${_formatVoiceDuration(duration)}'
                : _attachmentLabel('Video', widget.attachment);
    final playLabel = _failed
        ? 'Reintentar video'
        : playing
            ? 'Pausar video'
            : 'Reproducir video';

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 232,
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: Semantics(
            button: true,
            enabled: !_loading,
            label: playLabel,
            value: label,
            child: Tooltip(
              message: playLabel,
              child: GestureDetector(
                onTap: _togglePlayback,
                behavior: HitTestBehavior.opaque,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (initialized && controller != null)
                      VideoPlayer(controller)
                    else
                      Container(color: Colors.white.withValues(alpha: 0.08)),
                    if (overlayVisible)
                      Container(color: Colors.black.withValues(alpha: 0.34)),
                    Center(
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.94),
                          shape: BoxShape.circle,
                        ),
                        child: _loading
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.black,
                                ),
                              )
                            : Icon(icon, color: Colors.black, size: 26),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0),
                              Colors.black.withValues(alpha: 0.65),
                            ],
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                minHeight: 3,
                                value: progress,
                                backgroundColor:
                                    Colors.white.withValues(alpha: 0.24),
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                    Colors.white),
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.86),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                height: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
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

class _VoiceWaveform extends StatelessWidget {
  const _VoiceWaveform({required this.id, required this.progress});

  final String id;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final seed = id.codeUnits.fold<int>(0, (sum, value) => sum + value);
    const count = 26;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List.generate(count, (index) {
        final normalizedIndex = count == 1 ? 0.0 : index / (count - 1);
        final height = 7.0 + ((seed + index * 11) % 17).toDouble();
        final active = normalizedIndex <= progress;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 3,
          height: height,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: active ? 0.9 : 0.28),
            borderRadius: BorderRadius.circular(999),
          ),
        );
      }),
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
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: label,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          child: Align(
            alignment: Alignment.centerLeft,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 160),
              opacity: enabled ? 1 : 0.45,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
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
    required this.mediaEnabled,
    required this.showMediaControls,
    required this.recording,
    required this.recordingStartedAt,
    required this.stagedAttachments,
    required this.includeBottomInset,
    required this.onSend,
    required this.onPickMedia,
    required this.onRemoveAttachment,
    required this.onMicStart,
    required this.onMicStop,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final bool mediaEnabled;
  final bool showMediaControls;
  final bool recording;
  final DateTime? recordingStartedAt;
  final List<_PendingConsultAttachment> stagedAttachments;
  final bool includeBottomInset;
  final VoidCallback onSend;
  final VoidCallback onPickMedia;
  final ValueChanged<_PendingConsultAttachment> onRemoveAttachment;
  final VoidCallback onMicStart;
  final Future<void> Function({bool send}) onMicStop;

  @override
  Widget build(BuildContext context) {
    final bottomInset =
        includeBottomInset ? MediaQuery.paddingOf(context).bottom : 0.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 8, 18, 14 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (stagedAttachments.isNotEmpty) ...[
            _ComposerAttachmentTray(
              attachments: stagedAttachments,
              sending: sending,
              onRemove: onRemoveAttachment,
            ),
            const SizedBox(height: 8),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 46, maxHeight: 150),
            child: AnimatedBuilder(
              animation: focusNode,
              builder: (context, child) {
                return _ComposerFrame(
                  active: focusNode.hasFocus || sending || recording,
                  thinking: sending,
                  child: child!,
                );
              },
              child: Padding(
                padding: const EdgeInsets.only(
                    left: 18, right: 6, top: 3, bottom: 3),
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
                          hintText: recording
                              ? _formatRecordingElapsed(recordingStartedAt)
                              : sending
                                  ? 'Pensando...'
                                  : 'escribir mensaje...',
                          hintStyle: TextStyle(
                            color: Colors.white.withValues(alpha: 0.32),
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            height: 1.25,
                          ),
                        ),
                      ),
                    ),
                    if (showMediaControls) ...[
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: IconButton(
                          tooltip: 'Adjuntar imagen o video',
                          onPressed: mediaEnabled ? onPickMedia : null,
                          visualDensity: VisualDensity.compact,
                          style: IconButton.styleFrom(
                            fixedSize: const Size(44, 44),
                            padding: EdgeInsets.zero,
                          ),
                          icon: SvgPicture.asset(
                            'assets/icons/image-video.svg',
                            width: 17,
                            height: 17,
                            colorFilter: ColorFilter.mode(
                              Colors.white.withValues(
                                  alpha: mediaEnabled ? 0.72 : 0.24),
                              BlendMode.srcIn,
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Semantics(
                          button: true,
                          enabled: mediaEnabled,
                          label: recording
                              ? 'Soltar para adjuntar nota de voz'
                              : 'Mantener presionado para grabar nota de voz',
                          child: Tooltip(
                            message: recording ? 'Soltar voz' : 'Grabar voz',
                            child: GestureDetector(
                              onTapDown:
                                  mediaEnabled ? (_) => onMicStart() : null,
                              onTapUp: mediaEnabled ? (_) => onMicStop() : null,
                              onTapCancel: mediaEnabled
                                  ? () => onMicStop(send: false)
                                  : null,
                              behavior: HitTestBehavior.opaque,
                              child: SizedBox(
                                width: 44,
                                height: 44,
                                child: Center(
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 140),
                                    width: 34,
                                    height: 34,
                                    decoration: BoxDecoration(
                                      color: recording
                                          ? Colors.white
                                          : Colors.transparent,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.mic_rounded,
                                      size: 18,
                                      color: recording
                                          ? Colors.black
                                          : Colors.white.withValues(
                                              alpha:
                                                  mediaEnabled ? 0.72 : 0.24),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Padding(
                      padding: const EdgeInsets.only(bottom: 1),
                      child: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: controller,
                        builder: (context, value, _) {
                          final canSend = !sending &&
                              (value.text.trim().isNotEmpty ||
                                  stagedAttachments.isNotEmpty);
                          return IconButton.filled(
                            tooltip: 'Enviar mensaje',
                            onPressed: canSend ? onSend : null,
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.white,
                              disabledBackgroundColor:
                                  Colors.white.withValues(alpha: 0.16),
                              disabledForegroundColor:
                                  Colors.black.withValues(alpha: 0.36),
                              foregroundColor: Colors.black,
                              fixedSize: const Size(44, 44),
                            ),
                            icon: const Icon(Icons.arrow_upward_rounded,
                                size: 19),
                          );
                        },
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
  }
}

class _ComposerAttachmentTray extends StatelessWidget {
  const _ComposerAttachmentTray({
    required this.attachments,
    required this.sending,
    required this.onRemove,
  });

  final List<_PendingConsultAttachment> attachments;
  final bool sending;
  final ValueChanged<_PendingConsultAttachment> onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: attachments.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final attachment = attachments[index];
          return _ComposerAttachmentChip(
            attachment: attachment,
            sending: sending,
            onRemove: () => onRemove(attachment),
          );
        },
      ),
    );
  }
}

class _ComposerAttachmentChip extends StatelessWidget {
  const _ComposerAttachmentChip({
    required this.attachment,
    required this.sending,
    required this.onRemove,
  });

  final _PendingConsultAttachment attachment;
  final bool sending;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final isImage = attachment.kind == _ConsultAttachmentKind.image;
    final isVoice = attachment.kind == _ConsultAttachmentKind.voice;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: isVoice ? 232 : 72,
          height: isVoice ? 62 : 72,
          padding: EdgeInsets.all(isVoice || isImage ? 0 : 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(isVoice ? 18 : 14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          child: isVoice
              ? _ConsultVoiceNoteBubble(
                  attachment: attachment.toComposerAttachment())
              : ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: isImage
                      ? Image.file(File(attachment.path), fit: BoxFit.cover)
                      : ColoredBox(
                          color: Colors.white.withValues(alpha: 0.10),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                ),
        ),
        Positioned(
          top: -8,
          right: -8,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Center(
              child: IconButton.filled(
                tooltip: 'Quitar adjunto',
                onPressed: sending ? null : onRemove,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white,
                  disabledBackgroundColor: Colors.white.withValues(alpha: 0.35),
                  foregroundColor: Colors.black,
                  fixedSize: const Size(22, 22),
                  padding: EdgeInsets.zero,
                ),
                icon: const Icon(Icons.close_rounded, size: 13),
              ),
            ),
          ),
        ),
      ],
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

enum _ConsultAttachmentKind { image, video, voice }

enum _ConsultMediaChoice { camera, images, video }

class _PendingConsultAttachment {
  const _PendingConsultAttachment({
    required this.kind,
    required this.path,
    required this.fileName,
    required this.contentType,
    required this.byteSize,
    this.durationMs,
  });

  final _ConsultAttachmentKind kind;
  final String path;
  final String fileName;
  final String contentType;
  final int byteSize;
  final int? durationMs;

  factory _PendingConsultAttachment.fromJson(Map<String, dynamic> json) {
    final kindRaw = json['kind']?.toString().toLowerCase();
    final kind = switch (kindRaw) {
      'video' => _ConsultAttachmentKind.video,
      'voice' => _ConsultAttachmentKind.voice,
      _ => _ConsultAttachmentKind.image,
    };
    return _PendingConsultAttachment(
      kind: kind,
      path: json['path']?.toString() ?? '',
      fileName: json['fileName']?.toString() ??
          json['file_name']?.toString() ??
          'attachment',
      contentType: json['contentType']?.toString() ??
          json['content_type']?.toString() ??
          'application/octet-stream',
      byteSize: _asInt(json['byteSize'] ?? json['byte_size']) ?? 0,
      durationMs: _asInt(json['durationMs'] ?? json['duration_ms']),
    );
  }

  Map<String, dynamic> toUploadBody() => {
        'kind': kind.name,
        'fileName': fileName,
        'contentType': contentType,
        'byteSize': byteSize,
        if (durationMs != null) 'durationMs': durationMs,
      };

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'path': path,
        'fileName': fileName,
        'contentType': contentType,
        'byteSize': byteSize,
        if (durationMs != null) 'durationMs': durationMs,
      };

  _ConsultAttachment toPreviewAttachment() => _ConsultAttachment(
        id: path,
        kind: kind,
        contentType: contentType,
        byteSize: byteSize,
        durationMs: durationMs,
        localPath: path,
        status: 'uploading',
        uploadProgress: 0,
      );

  _ConsultAttachment toComposerAttachment() => _ConsultAttachment(
        id: path,
        kind: kind,
        contentType: contentType,
        byteSize: byteSize,
        durationMs: durationMs,
        localPath: path,
      );
}

class _ConsultOutboxEntry {
  const _ConsultOutboxEntry({
    required this.sessionId,
    required this.clientKey,
    required this.text,
    required this.attachments,
    required this.status,
    required this.attempts,
    required this.createdAt,
    required this.updatedAt,
    this.lastError,
    this.lastErrorCode,
    this.nextRetryAt,
  });

  final String sessionId;
  final String clientKey;
  final String text;
  final List<_PendingConsultAttachment> attachments;
  final String status;
  final int attempts;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? lastError;
  final String? lastErrorCode;
  final DateTime? nextRetryAt;

  bool get retryDue =>
      nextRetryAt == null || !nextRetryAt!.isAfter(DateTime.now());

  factory _ConsultOutboxEntry.fromJson(Map<String, dynamic> json) {
    return _ConsultOutboxEntry(
      sessionId: json['sessionId']?.toString() ?? '',
      clientKey: json['clientKey']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      attachments: (_asList(json['attachments']) ?? const [])
          .map(_asMap)
          .whereType<Map<String, dynamic>>()
          .map(_PendingConsultAttachment.fromJson)
          .where((attachment) => attachment.path.isNotEmpty)
          .toList(growable: false),
      status: json['status']?.toString() ?? 'queued',
      attempts: _asInt(json['attempts']) ?? 0,
      createdAt: _parseDateTime(json['createdAt']) ?? DateTime.now(),
      updatedAt: _parseDateTime(json['updatedAt']) ?? DateTime.now(),
      lastError: json['lastError']?.toString(),
      lastErrorCode: json['lastErrorCode']?.toString(),
      nextRetryAt: _parseDateTime(json['nextRetryAt']),
    );
  }

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'clientKey': clientKey,
        'text': text,
        'attachments': attachments
            .map((attachment) => attachment.toJson())
            .toList(growable: false),
        'status': status,
        'attempts': attempts,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        if (lastError != null) 'lastError': lastError,
        if (lastErrorCode != null) 'lastErrorCode': lastErrorCode,
        if (nextRetryAt != null) 'nextRetryAt': nextRetryAt!.toIso8601String(),
      };

  _ConsultOutboxEntry copyWith({
    String? status,
    int? attempts,
    DateTime? updatedAt,
    String? lastError,
    String? lastErrorCode,
    DateTime? nextRetryAt,
  }) {
    return _ConsultOutboxEntry(
      sessionId: sessionId,
      clientKey: clientKey,
      text: text,
      attachments: attachments,
      status: status ?? this.status,
      attempts: attempts ?? this.attempts,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastError: lastError ?? this.lastError,
      lastErrorCode: lastErrorCode ?? this.lastErrorCode,
      nextRetryAt: nextRetryAt ?? this.nextRetryAt,
    );
  }

  _ChatMessage toMessage() => _ChatMessage.user(
        text,
        id: clientKey,
        clientKey: clientKey,
        deliveryState: status,
        includeInHistory: false,
        attachments: attachments
            .map((attachment) => attachment.toPreviewAttachment())
            .toList(growable: false),
      );
}

class _ConsultOutboxStore {
  static const _fileName = 'owner_consult_chat_outbox.json';

  static Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File('${directory.path}/$_fileName');
  }

  static Future<List<_ConsultOutboxEntry>> _readAll() async {
    try {
      final file = await _file();
      if (!await file.exists()) return <_ConsultOutboxEntry>[];
      final decoded = jsonDecode(await file.readAsString());
      return (_asList(decoded) ?? const [])
          .map(_asMap)
          .whereType<Map<String, dynamic>>()
          .map(_ConsultOutboxEntry.fromJson)
          .where((entry) =>
              entry.sessionId.isNotEmpty && entry.clientKey.isNotEmpty)
          .toList(growable: true);
    } catch (_) {
      return <_ConsultOutboxEntry>[];
    }
  }

  static Future<void> _writeAll(List<_ConsultOutboxEntry> entries) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(
        entries.map((entry) => entry.toJson()).toList(growable: false)));
  }

  static Future<List<_ConsultOutboxEntry>> entriesForSession(
      String sessionId) async {
    final entries = await _readAll();
    return entries
        .where((entry) => entry.sessionId == sessionId)
        .toList(growable: false)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  static Future<void> upsert(_ConsultOutboxEntry entry) async {
    final entries = await _readAll();
    final index = entries
        .indexWhere((candidate) => candidate.clientKey == entry.clientKey);
    if (index >= 0) {
      entries[index] = entry;
    } else {
      entries.add(entry);
    }
    await _writeAll(entries);
  }

  static Future<void> remove(String clientKey) async {
    final entries = await _readAll();
    entries.removeWhere((entry) => entry.clientKey == clientKey);
    await _writeAll(entries);
  }
}

class _ConsultDraftStore {
  static const _fileName = 'owner_consult_chat_drafts.json';

  static Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File('${directory.path}/$_fileName');
  }

  static Future<Map<String, String>> _readAll() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const {};
      final decoded = jsonDecode(await file.readAsString());
      final map = _asMap(decoded);
      if (map == null) return const {};
      return map.map((key, value) => MapEntry(key, value?.toString() ?? ''));
    } catch (_) {
      return const {};
    }
  }

  static Future<void> _writeAll(Map<String, String> drafts) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(drafts));
  }

  static Future<String?> read(String sessionId) async {
    final drafts = await _readAll();
    return drafts[sessionId];
  }

  static Future<void> save(String sessionId, String draft) async {
    final drafts = Map<String, String>.from(await _readAll());
    final trimmed = draft.trim();
    if (trimmed.isEmpty) {
      drafts.remove(sessionId);
    } else {
      drafts[sessionId] = draft;
    }
    await _writeAll(drafts);
  }

  static Future<void> clear(String sessionId) => save(sessionId, '');
}

class _ConsultAttachment {
  const _ConsultAttachment({
    required this.id,
    required this.kind,
    required this.contentType,
    required this.byteSize,
    this.width,
    this.height,
    this.durationMs,
    this.downloadUrl,
    this.thumbnailUrl,
    this.localPath,
    this.status,
    this.uploadProgress = 0,
  });

  factory _ConsultAttachment.fromJson(Map<String, dynamic> json) {
    final kindRaw = json['kind']?.toString().toLowerCase();
    final kind = switch (kindRaw) {
      'video' => _ConsultAttachmentKind.video,
      'voice' => _ConsultAttachmentKind.voice,
      _ => _ConsultAttachmentKind.image,
    };
    return _ConsultAttachment(
      id: json['id']?.toString() ?? _nextChatMessageId(),
      kind: kind,
      contentType: json['contentType']?.toString() ??
          json['content_type']?.toString() ??
          '',
      byteSize: _asInt(json['byteSize'] ?? json['byte_size']) ?? 0,
      width: _asInt(json['width']),
      height: _asInt(json['height']),
      durationMs: _asInt(json['durationMs'] ?? json['duration_ms']),
      downloadUrl:
          json['downloadUrl']?.toString() ?? json['download_url']?.toString(),
      thumbnailUrl:
          json['thumbnailUrl']?.toString() ?? json['thumbnail_url']?.toString(),
      status: json['status']?.toString(),
      uploadProgress: _asDouble(json['uploadProgress']) ?? 0,
    );
  }

  final String id;
  final _ConsultAttachmentKind kind;
  final String contentType;
  final int byteSize;
  final int? width;
  final int? height;
  final int? durationMs;
  final String? downloadUrl;
  final String? thumbnailUrl;
  final String? localPath;
  final String? status;
  final double uploadProgress;

  bool get isUploading => status == 'uploading';

  _ConsultAttachment copyWith({
    String? status,
    double? uploadProgress,
  }) {
    return _ConsultAttachment(
      id: id,
      kind: kind,
      contentType: contentType,
      byteSize: byteSize,
      width: width,
      height: height,
      durationMs: durationMs,
      downloadUrl: downloadUrl,
      thumbnailUrl: thumbnailUrl,
      localPath: localPath,
      status: status ?? this.status,
      uploadProgress: uploadProgress ?? this.uploadProgress,
    );
  }

  _ConsultAttachment withMediaFrom(_ConsultAttachment previous) {
    return _ConsultAttachment(
      id: id,
      kind: kind,
      contentType: contentType,
      byteSize: byteSize,
      width: width ?? previous.width,
      height: height ?? previous.height,
      durationMs: durationMs ?? previous.durationMs,
      downloadUrl: _nonEmpty(downloadUrl) ?? _nonEmpty(previous.downloadUrl),
      thumbnailUrl: _nonEmpty(thumbnailUrl) ?? _nonEmpty(previous.thumbnailUrl),
      localPath: _nonEmpty(localPath) ?? _nonEmpty(previous.localPath),
      status: status ?? previous.status,
      uploadProgress:
          uploadProgress > 0 ? uploadProgress : previous.uploadProgress,
    );
  }
}

class _ChatMessage {
  _ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    this.senderId,
    this.clientKey,
    this.streamOrder,
    this.createdAt,
    this.deliveredByOther = false,
    this.readByOther = false,
    this.result,
    this.rejoinSessionId,
    this.surveyAction,
    this.includeInHistory = true,
    this.attachments = const [],
    this.deliveryState,
  });

  factory _ChatMessage.user(
    String text, {
    String? id,
    String? clientKey,
    String? deliveryState,
    bool includeInHistory = true,
    List<_ConsultAttachment> attachments = const [],
  }) {
    return _ChatMessage(
      id: id ?? _nextChatMessageId(),
      role: _ChatRole.user,
      text: text,
      clientKey: clientKey,
      deliveryState: deliveryState,
      includeInHistory: includeInHistory,
      attachments: attachments,
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
      createdAt: _parseDateTime(json['created_at']),
      includeInHistory: false,
      attachments: (_asList(json['attachments']) ?? const [])
          .map(_asMap)
          .whereType<Map<String, dynamic>>()
          .map(_ConsultAttachment.fromJson)
          .toList(growable: false),
    );
  }

  final String id;
  final _ChatRole role;
  final String text;
  final String? senderId;
  final String? clientKey;
  final int? streamOrder;
  final DateTime? createdAt;
  final bool deliveredByOther;
  final bool readByOther;
  final _AiChatTurnResult? result;
  final String? rejoinSessionId;
  final _SurveyAction? surveyAction;
  final bool includeInHistory;
  final List<_ConsultAttachment> attachments;
  final String? deliveryState;

  bool get isUser => role == _ChatRole.user;
  bool get hasAttachments => attachments.isNotEmpty;

  String? consultLabel({required String vetName}) {
    if (streamOrder == null && isUser) {
      return switch (deliveryState) {
        'failed' => 'Failed',
        'retrying' => 'Retrying...',
        'queued' => 'Queued',
        'sending' => 'Sending...',
        _ => null,
      };
    }
    if (streamOrder == null) return null;
    if (role == _ChatRole.assistant) return null;
    final time = createdAt == null
        ? null
        : '${createdAt!.hour.toString().padLeft(2, '0')}:${createdAt!.minute.toString().padLeft(2, '0')}';
    if (isUser) {
      final receipt = readByOther
          ? 'Read'
          : deliveredByOther
              ? 'Delivered'
              : null;
      if (time == null) return receipt;
      return receipt == null ? time : '$time · $receipt';
    }
    final trimmedName = vetName.trim();
    final name = trimmedName.isEmpty ? 'MVZ vet' : 'MVZ $trimmedName';
    return time == null ? name : '$name · $time';
  }

  _ChatMessage copyWith({
    bool? deliveredByOther,
    bool? readByOther,
    List<_ConsultAttachment>? attachments,
    String? deliveryState,
  }) {
    return _ChatMessage(
      id: id,
      role: role,
      text: text,
      senderId: senderId,
      clientKey: clientKey,
      streamOrder: streamOrder,
      createdAt: createdAt,
      deliveredByOther: deliveredByOther ?? this.deliveredByOther,
      readByOther: readByOther ?? this.readByOther,
      result: result,
      rejoinSessionId: rejoinSessionId,
      surveyAction: surveyAction,
      includeInHistory: includeInHistory,
      attachments: attachments ?? this.attachments,
      deliveryState: deliveryState ?? this.deliveryState,
    );
  }

  _ChatMessage withReceiptFrom(_ChatMessage previous) {
    return copyWith(
      deliveredByOther: previous.deliveredByOther,
      readByOther: previous.readByOther,
      attachments: _mergeConsultAttachments(attachments, previous.attachments),
    );
  }
}

List<_ConsultAttachment>? _mergeConsultAttachments(
    List<_ConsultAttachment> current, List<_ConsultAttachment> previous) {
  if (current.isEmpty && previous.isNotEmpty) return previous;
  if (current.isEmpty || previous.isEmpty) return null;
  final previousById = {
    for (final attachment in previous) attachment.id: attachment
  };
  var changed = false;
  final merged = current.map((attachment) {
    final prior = previousById[attachment.id];
    if (prior == null) return attachment;
    final next = attachment.withMediaFrom(prior);
    if (!identical(next, attachment) &&
        (next.downloadUrl != attachment.downloadUrl ||
            next.thumbnailUrl != attachment.thumbnailUrl ||
            next.localPath != attachment.localPath ||
            next.uploadProgress != attachment.uploadProgress)) {
      changed = true;
    }
    return next;
  }).toList(growable: false);
  return changed ? merged : null;
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : value;
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

class _ConsultUploadCanceledException implements Exception {
  const _ConsultUploadCanceledException();

  @override
  String toString() => 'upload_canceled';
}

class _ConsultUploadCancelToken {
  bool _canceled = false;

  bool get canceled => _canceled;

  void cancel() {
    _canceled = true;
  }
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

double? _asDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

String _uploadProgressText(_ConsultAttachment attachment) {
  final percent = (attachment.uploadProgress.clamp(0.0, 1.0) * 100).round();
  return '$percent%';
}

String _formatRecordingElapsed(DateTime? startedAt) {
  final elapsed =
      startedAt == null ? Duration.zero : DateTime.now().difference(startedAt);
  final minutes = elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

DateTime? _parseDateTime(Object? value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString())?.toLocal();
}

String _contentTypeForFile(String path, _ConsultAttachmentKind kind) {
  final lower = path.toLowerCase();
  if (kind == _ConsultAttachmentKind.voice) return 'audio/mp4';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'image/heic';
  if (lower.endsWith('.mov')) return 'video/quicktime';
  if (lower.endsWith('.webm')) return 'video/webm';
  if (kind == _ConsultAttachmentKind.video) return 'video/mp4';
  return 'image/jpeg';
}

void _validatePendingAttachment(
    _ConsultAttachmentKind kind, int byteSize, int? durationMs) {
  final maxBytes = switch (kind) {
    _ConsultAttachmentKind.image => 8 * 1024 * 1024,
    _ConsultAttachmentKind.video => 50 * 1024 * 1024,
    _ConsultAttachmentKind.voice => 15 * 1024 * 1024,
  };
  if (byteSize > maxBytes) {
    throw const _ChatApiException(
        'El archivo es demasiado grande para enviarlo.');
  }
  if (kind == _ConsultAttachmentKind.voice &&
      durationMs != null &&
      durationMs > 300000) {
    throw const _ChatApiException(
        'La nota de voz no puede pasar de 5 minutos.');
  }
}

String _attachmentLabel(String label, _ConsultAttachment attachment) {
  final duration = attachment.durationMs;
  if (duration == null || duration <= 0) return label;
  return '$label · ${_formatVoiceDuration(Duration(milliseconds: duration))}';
}

String _formatVoiceDuration(Duration duration) {
  final seconds = duration.inSeconds;
  final minutes = seconds ~/ 60;
  final rest = (seconds % 60).toString().padLeft(2, '0');
  return '$minutes:$rest';
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
