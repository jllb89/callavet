import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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

const _vetAssistantSessionId = 'assistant';
int _vetAssistantMessageSequence = 0;
final _activeVetVoiceNoteId = ValueNotifier<String?>(null);
final _activeVetVideoId = ValueNotifier<String?>(null);

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

class _VetChatScreenState extends State<VetChatScreen>
    with WidgetsBindingObserver {
  final TextEditingController _composerController = TextEditingController();
  final FocusNode _composerFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final List<_VetChatMessage> _assistantMessages = <_VetChatMessage>[];
  final List<_VetChatMessage> _consultMessages = <_VetChatMessage>[];
  final List<_PendingVetAttachment> _stagedVetAttachments =
      <_PendingVetAttachment>[];
  final _uploadCancelTokens = <String, _VetUploadCancelToken>{};
  final ImagePicker _imagePicker = ImagePicker();
  final AudioRecorder _audioRecorder = AudioRecorder();
  RealtimeChannel? _messagesChannel;
  RealtimeChannel? _sessionChannel;
  RealtimeChannel? _roomChannel;
  bool _disposing = false;
  Timer? _refreshDebounce;
  Timer? _reconnectTimer;
  Timer? _readReceiptDebounce;
  Timer? _handoffRetryTimer;
  Timer? _draftDebounce;
  Timer? _typingDebounce;
  Timer? _remoteTypingClearTimer;
  Timer? _recordingTicker;
  _VetHandoffBrief? _handoffBrief;
  Object? _consultLoadError;
  bool _sending = false;
  bool _returningDashboard = false;
  bool _consultLoading = false;
  bool _consultClosed = false;
  bool _endingConsult = false;
  bool _recordingVoice = false;
  DateTime? _recordingStartedAt;
  bool _ownerOnline = false;
  bool _ownerTyping = false;
  bool _handoffPending = false;
  bool _outboxFlushing = false;
  bool _catchUpInFlight = false;
  bool _showDraftRestoredBanner = false;
  int _reconnectAttempts = 0;
  int _handoffRetryAttempts = 0;
  DateTime? _lastOwnerTypingAt;
  String? _unreadMarkerMessageId;
  String? _realtimeStatus;
  String _ownerName = 'tutor';

  static const _returnDashboardFadeDuration = Duration(milliseconds: 260);
  static const _maxHandoffRetryAttempts = 8;
  static const _consultSendTimeout = Duration(seconds: 25);

  bool get _isAssistant => widget.sessionId == _vetAssistantSessionId;

  void _traceMessageList(String event, Map<String, Object?> metadata) {
    debugPrint(
      '[VetChat] messages.$event $metadata total=${_consultMessages.length}',
    );
  }

  String get _assistantDisplayName {
    final trimmed = widget.displayName?.trim();
    return trimmed == null || trimmed.isEmpty ? 'Doctor' : trimmed;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _composerFocusNode.addListener(_handleComposerFocusChanged);
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
      unawaited(_restoreDraft());
      unawaited(_loadConsultThread());
      _startMessagesRealtime();
      _startSessionRealtime();
      _startRoomSignals();
    }
  }

  @override
  void dispose() {
    _disposing = true;
    WidgetsBinding.instance.removeObserver(this);
    _refreshDebounce?.cancel();
    _reconnectTimer?.cancel();
    _readReceiptDebounce?.cancel();
    _handoffRetryTimer?.cancel();
    _draftDebounce?.cancel();
    _persistCurrentDraft();
    _sendTyping(false);
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
    _recordingTicker?.cancel();
    _audioRecorder.dispose();
    _composerController.dispose();
    _composerFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _isAssistant || _consultClosed) {
      if (!_isAssistant) _sendTyping(false);
      return;
    }
    unawaited(_catchUpMessages());
    unawaited(_flushOutbox());
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
      final handoffBrief = _VetHandoffBrief.fromJson(handoffResponse);
      final handoffReady = handoffResponse['ready'] == true;
      final hasUsableHandoff = handoffReady && !handoffBrief.isEmpty;
      final messages = _asList(messagesResponse['items'])
              ?.map(_asMap)
              .whereType<Map<String, dynamic>>()
              .map(_VetChatMessage.fromJson)
              .toList() ??
          const <_VetChatMessage>[];
      messages.sort(_compareMessages);
      final outboxEntries =
          await _VetOutboxStore.entriesForSession(widget.sessionId);
      final session = _asMap(messagesResponse['session']);
      final status = session?['status']?.toString().toLowerCase();
      final ownerName = session?['ownerName']?.toString().trim();
      final receipts = _asList(messagesResponse['receipts']) ?? const [];
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
        _consultMessages
          ..clear()
          ..addAll(hydratedMessages)
          ..addAll(outboxMessages)
          ..sort(_compareMessages);
        if (hasUsableHandoff) {
          _handoffBrief = handoffBrief;
          _handoffPending = false;
          _handoffRetryAttempts = 0;
        } else if (_handoffBrief == null && !_isClosedStatus(status)) {
          _handoffPending = true;
        }
        _consultClosed = _isClosedStatus(status);
        if (ownerName != null && ownerName.isNotEmpty) {
          _ownerName = ownerName;
        }
        _consultLoadError = null;
      });
      if (hasUsableHandoff) {
        _handoffRetryTimer?.cancel();
      } else if (!_isClosedStatus(status)) {
        _scheduleHandoffRetry();
      }
      _traceMessageList('load', {
        'server': messages.length,
        'outbox': outboxEntries.length,
        'status': status,
      });
      _markVisibleMessagesRead();
      unawaited(_flushOutbox());
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
    _messagesChannel = channel;
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
          _scheduleFullRefresh();
          return;
        }
        if (_hasStreamGap(message)) _scheduleRefresh();
        _upsertConsultMessage(message);
        if (message.role != 'vet' || message.content.trim().isEmpty) {
          _scheduleFullRefresh();
        }
      },
    )
        .subscribe((status, [_]) {
      if (!identical(_messagesChannel, channel)) return;
      _handleRealtimeStatus(
        status,
        drivesReconnect: true,
        catchUpOnSubscribe: true,
      );
    });
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
    _roomChannel = channel;
    channel
        .onBroadcast(
          event: 'typing',
          callback: (payload) {
            if (payload['role']?.toString() != 'user') return;
            final typing = payload['typing'] == true;
            final eventAt = _parseDateTime(payload['at']) ?? DateTime.now();
            if (typing && DateTime.now().difference(eventAt).inSeconds > 8) {
              return;
            }
            if (!mounted) return;
            final wasTyping = _ownerTyping;
            if (wasTyping == typing && _lastOwnerTypingAt == eventAt) return;
            setState(() {
              _lastOwnerTypingAt = typing ? eventAt : null;
              _ownerTyping = typing;
            });
            if (typing && !wasTyping) {
              _announceForAccessibility('El tutor está escribiendo.');
            }
            _remoteTypingClearTimer?.cancel();
            if (typing) {
              _remoteTypingClearTimer = Timer(
                const Duration(seconds: 3),
                () {
                  if (!mounted || _lastOwnerTypingAt != eventAt) return;
                  setState(() {
                    _ownerTyping = false;
                    _lastOwnerTypingAt = null;
                  });
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
        .onBroadcast(
          event: 'messages',
          callback: (payload) {
            final record = _asMap(payload['message']);
            if (record == null) {
              _scheduleFullRefresh();
              return;
            }
            final message = _VetChatMessage.fromJson(record);
            if (message.id.isEmpty) {
              _scheduleFullRefresh();
              return;
            }
            _upsertConsultMessage(message);
            if (message.role != 'vet' || message.content.trim().isEmpty) {
              _scheduleFullRefresh();
            }
          },
        )
        .onPresenceSync((_) => _syncOwnerPresence(channel))
        .subscribe((status, [_]) {
      if (!identical(_roomChannel, channel)) return;
      if (status == RealtimeSubscribeStatus.subscribed) {
        _handleRealtimeStatus(status);
        unawaited(channel.track({
          'role': 'vet',
          'userId': userId,
          'onlineAt': DateTime.now().toIso8601String(),
        }));
      } else {
        _handleRealtimeStatus(status);
      }
    });
  }

  void _handleRealtimeStatus(
    RealtimeSubscribeStatus status, {
    bool drivesReconnect = false,
    bool catchUpOnSubscribe = false,
  }) {
    if (!mounted || _disposing) return;
    if (status == RealtimeSubscribeStatus.subscribed) {
      if (drivesReconnect) {
        _reconnectAttempts = 0;
        _reconnectTimer?.cancel();
      }
      if (_realtimeStatus != null) {
        if (!mounted || _disposing) return;
        setState(() => _realtimeStatus = null);
      }
      if (catchUpOnSubscribe) unawaited(_catchUpMessages());
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
    if (_realtimeStatus != nextStatus) {
      setState(() => _realtimeStatus = nextStatus);
    }
    _emitTelemetry('realtime_reconnect', metadata: {
      'status': status.name,
      'reconnectAttempt': _reconnectAttempts + 1,
    });
    _scheduleRealtimeRestart();
  }

  void _scheduleRealtimeRestart() {
    if (_isAssistant || _reconnectTimer?.isActive == true) return;
    final delaySeconds = math.min(10, 1 << _reconnectAttempts);
    _reconnectAttempts = math.min(_reconnectAttempts + 1, 4);
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      if (!mounted || _consultClosed || _isAssistant) return;
      _stopRealtime();
      _startMessagesRealtime();
      _startSessionRealtime();
      _startRoomSignals();
      unawaited(_catchUpMessages());
    });
  }

  void _stopRealtime() {
    final messagesChannel = _messagesChannel;
    if (messagesChannel != null) {
      _messagesChannel = null;
      Supabase.instance.client.removeChannel(messagesChannel);
    }
    final sessionChannel = _sessionChannel;
    if (sessionChannel != null) {
      _sessionChannel = null;
      Supabase.instance.client.removeChannel(sessionChannel);
    }
    final roomChannel = _roomChannel;
    if (roomChannel != null) {
      _roomChannel = null;
      unawaited(roomChannel.untrack());
      Supabase.instance.client.removeChannel(roomChannel);
    }
  }

  void _syncOwnerPresence(RealtimeChannel channel) {
    final online = channel.presenceState().any((state) => state.presences.any(
          (presence) => presence.payload['role']?.toString() == 'user',
        ));
    if (mounted) {
      final wasOnline = _ownerOnline;
      if (wasOnline == online) return;
      setState(() => _ownerOnline = online);
      if (online && !wasOnline) {
        _announceForAccessibility('El tutor está en línea.');
      }
    }
  }

  void _handleComposerChanged() {
    if (_isAssistant || _consultClosed || _roomChannel == null) return;
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(
          _VetDraftStore.save(widget.sessionId, _composerController.text));
    });
    if (_showDraftRestoredBanner && _composerController.text.trim().isEmpty) {
      _dismissDraftBanner();
    }
    _typingDebounce?.cancel();
    final isTyping = _composerController.text.trim().isNotEmpty;
    _typingDebounce = Timer(const Duration(milliseconds: 300), () {
      _sendTyping(isTyping);
    });
  }

  void _handleComposerFocusChanged() {
    if (!_composerFocusNode.hasFocus) _sendTyping(false);
  }

  Future<void> _restoreDraft() async {
    if (_isAssistant) return;
    final draft = await _VetDraftStore.read(widget.sessionId);
    if (!mounted || draft == null || draft.trim().isEmpty) return;
    if (_composerController.text.trim().isNotEmpty) return;
    _composerController.text = draft;
    _composerController.selection =
        TextSelection.collapsed(offset: draft.length);
    setState(() => _showDraftRestoredBanner = true);
    _announceForAccessibility('Borrador restaurado.');
  }

  void _dismissDraftBanner() {
    if (!mounted || !_showDraftRestoredBanner) return;
    setState(() => _showDraftRestoredBanner = false);
  }

  void _persistCurrentDraft() {
    if (_isAssistant) return;
    unawaited(_VetDraftStore.save(widget.sessionId, _composerController.text));
  }

  void _sendTyping(bool typing) {
    final channel = _roomChannel;
    if (channel == null) return;
    _typingDebounce?.cancel();
    unawaited(channel.sendBroadcastMessage(
      event: 'typing',
      payload: {
        'role': 'vet',
        'typing': typing,
        'at': DateTime.now().toIso8601String(),
      },
    ));
  }

  void _scheduleRefresh() {
    _traceMessageList('refresh.schedule_catchup', {
      'lastStreamOrder': _lastConsultStreamOrder,
    });
    _refreshDebounce?.cancel();
    _refreshDebounce =
        Timer(const Duration(milliseconds: 450), _refreshMessages);
  }

  void _scheduleFullRefresh() {
    _traceMessageList('refresh.schedule_full', {
      'lastStreamOrder': _lastConsultStreamOrder,
    });
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(
      const Duration(milliseconds: 450),
      () => unawaited(_loadConsultThread()),
    );
  }

  void _scheduleHandoffRetry() {
    if (_isAssistant || _handoffBrief != null || _consultClosed) return;
    if (_handoffRetryAttempts >= _maxHandoffRetryAttempts) return;
    _handoffRetryTimer?.cancel();
    final attempt = _handoffRetryAttempts++;
    final delayMs = math.min(3600, 650 + (attempt * 450));
    _handoffRetryTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted || _handoffBrief != null || _consultClosed) return;
      unawaited(_refreshHandoffBrief());
    });
  }

  Future<void> _refreshHandoffBrief() async {
    try {
      final response = await _getGatewayJson(
        '/sessions/${Uri.encodeComponent(widget.sessionId)}/handoff',
      );
      final brief = _VetHandoffBrief.fromJson(response);
      final ready = response['ready'] == true;
      if (!mounted) return;
      if (ready && !brief.isEmpty) {
        setState(() {
          _handoffBrief = brief;
          _handoffPending = false;
          _handoffRetryAttempts = 0;
        });
        _handoffRetryTimer?.cancel();
      } else {
        setState(() => _handoffPending = true);
        _scheduleHandoffRetry();
      }
    } catch (_) {
      _scheduleHandoffRetry();
    }
  }

  void _refreshMessages() {
    if (!mounted) return;
    unawaited(_catchUpMessages());
  }

  int get _lastConsultStreamOrder => _consultMessages
      .map((message) => message.streamOrder ?? 0)
      .fold<int>(0, (max, value) => value > max ? value : max);

  bool _hasStreamGap(_VetChatMessage message) {
    final order = message.streamOrder;
    final lastOrder = _lastConsultStreamOrder;
    return order != null && lastOrder > 0 && order > lastOrder + 1;
  }

  Future<void> _catchUpMessages() async {
    if (_isAssistant) return;
    if (_catchUpInFlight) return;
    _catchUpInFlight = true;
    final afterStreamOrder = _lastConsultStreamOrder;
    try {
      if (afterStreamOrder <= 0) {
        await _loadConsultThread();
        return;
      }
      final startedAt = DateTime.now();
      final response = await _getGatewayJson(
        '/sessions/${Uri.encodeComponent(widget.sessionId)}/messages?afterStreamOrder=$afterStreamOrder&limit=100&sort=stream_order.asc',
      );
      final messages = (_asList(response['items']) ?? const [])
          .map(_asMap)
          .whereType<Map<String, dynamic>>()
          .map(_VetChatMessage.fromJson)
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
        if (message.role != 'vet') {
          firstIncoming = message.id;
          break;
        }
      }
      if (firstIncoming != null && mounted) {
        setState(() => _unreadMarkerMessageId = firstIncoming);
      }
      if (messages.isNotEmpty) _markVisibleMessagesRead();
      unawaited(_flushOutbox());
      _emitTelemetry(
        'realtime_catchup',
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
        valueCount: messages.length,
        metadata: {
          'afterStreamOrder': afterStreamOrder,
          'cursor': response['cursor'],
        },
      );
    } catch (_) {
      await _loadConsultThread();
    } finally {
      _catchUpInFlight = false;
    }
  }

  void _upsertConsultMessage(_VetChatMessage message) {
    if (!mounted) return;
    var inserted = false;
    setState(() {
      final index = _consultMessages.indexWhere((existing) =>
          existing.id == message.id ||
          (message.clientKey != null &&
              existing.clientKey == message.clientKey));
      if (index >= 0) {
        _consultMessages[index] =
            message.withReceiptFrom(_consultMessages[index]);
      } else {
        _consultMessages.add(message);
        inserted = true;
      }
      _consultMessages.sort(_compareMessages);
    });
    _traceMessageList(inserted ? 'upsert.insert' : 'upsert.replace', {
      'id': message.id,
      'clientKey': message.clientKey,
      'streamOrder': message.streamOrder,
      'attachments': message.attachments.length,
    });
    if (message.streamOrder != null && message.clientKey != null) {
      unawaited(_VetOutboxStore.remove(message.clientKey!));
    }
    if (message.role != 'vet') {
      if (inserted) _announceForAccessibility('Nuevo mensaje del tutor.');
      _markVisibleMessagesRead();
    }
    _scrollToBottom();
  }

  _VetChatMessage _mergeExistingConsultMessageMedia(_VetChatMessage message) {
    final index = _consultMessages.indexWhere((existing) =>
        existing.id == message.id ||
        (message.clientKey != null && existing.clientKey == message.clientKey));
    if (index < 0) return message;
    return message.withReceiptFrom(_consultMessages[index]);
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
    var applied = false;
    setState(() {
      final index =
          _consultMessages.indexWhere((message) => message.id == messageId);
      if (index < 0 || _consultMessages[index].role != 'vet') return;
      _consultMessages[index] = _consultMessages[index].copyWith(
        deliveredByOther: receipt['delivered_at'] != null,
        readByOther: receipt['read_at'] != null,
      );
      applied = true;
    });
    if (applied) _traceMessageList('receipt.apply', {'messageId': messageId});
  }

  void _markVisibleMessagesRead() {
    final lastStreamOrder = _consultMessages
        .where((message) => message.role != 'vet')
        .map((message) => message.streamOrder ?? 0)
        .fold<int>(0, (max, value) => value > max ? value : max);
    if (lastStreamOrder <= 0) return;
    _readReceiptDebounce?.cancel();
    _readReceiptDebounce = Timer(const Duration(milliseconds: 250), () {
      final startedAt = DateTime.now();
      unawaited(_postGatewayJson(
        '/sessions/${Uri.encodeComponent(widget.sessionId)}/messages/read',
        {'lastStreamOrder': lastStreamOrder},
      ).then((_) {
        _emitTelemetry(
          'read_receipt_sent',
          valueMs: DateTime.now().difference(startedAt).inMilliseconds,
          metadata: {'streamOrder': lastStreamOrder},
        );
      }).catchError((_) {}));
    });
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
    final stagedAttachments = List<_PendingVetAttachment>.unmodifiable(
      _stagedVetAttachments,
    );
    if ((text.isEmpty && stagedAttachments.isEmpty) ||
        _sending ||
        _consultClosed) {
      return;
    }
    _sendTyping(false);
    unawaited(_VetDraftStore.clear(widget.sessionId));
    _dismissDraftBanner();
    setState(() => _stagedVetAttachments.clear());
    await _sendConsultPayload(
      text: text,
      clearComposer: true,
      pendingAttachments: stagedAttachments,
    );
  }

  Future<void> _sendConsultPayload({
    String text = '',
    bool clearComposer = false,
    List<_PendingVetAttachment> pendingAttachments = const [],
    String? clientKeyOverride,
    bool retrying = false,
    int? attemptsOverride,
  }) async {
    if (_isAssistant || _sending || _consultClosed) return;
    final trimmedText = text.trim();
    if (trimmedText.isEmpty && pendingAttachments.isEmpty) return;
    _sendTyping(false);
    final clientKey = clientKeyOverride ??
        'vet-${DateTime.now().microsecondsSinceEpoch}-${_nextVetAssistantMessageId()}';
    final sendStartedAt = DateTime.now();
    _emitTelemetry('send_started', clientKey: clientKey, metadata: {
      'attachmentCount': pendingAttachments.length,
      'retrying': retrying,
    });
    final outboxEntry = _VetOutboxEntry(
      sessionId: widget.sessionId,
      clientKey: clientKey,
      text: trimmedText,
      attachments: pendingAttachments,
      status: retrying ? 'retrying' : 'sending',
      attempts: attemptsOverride ?? (retrying ? 1 : 0),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await _VetOutboxStore.upsert(outboxEntry);
    final optimisticMessage = outboxEntry.toMessage();
    setState(() {
      final index = _consultMessages.indexWhere((message) =>
          message.id == optimisticMessage.id ||
          message.clientKey == optimisticMessage.clientKey);
      if (index >= 0) {
        _consultMessages[index] =
            optimisticMessage.withReceiptFrom(_consultMessages[index]);
      } else {
        _consultMessages.add(optimisticMessage);
      }
      _consultMessages.sort(_compareMessages);
      _sending = true;
    });
    _scrollToBottom();
    try {
      final attachmentRefs = <Map<String, String>>[];
      for (final attachment in pendingAttachments) {
        final uploaded = await _uploadConsultAttachment(
          attachment,
          clientKey: clientKey,
        );
        attachmentRefs.add({'id': uploaded.id});
      }
      final response = await _postGatewayJson(
          '/sessions/${Uri.encodeComponent(widget.sessionId)}/messages', {
        'content': trimmedText,
        'clientKey': clientKey,
        if (attachmentRefs.isNotEmpty) 'attachments': attachmentRefs,
      }).timeout(_consultSendTimeout);
      await _VetOutboxStore.remove(clientKey);
      if (clearComposer) _composerController.clear();
      final message = _asMap(response['message']);
      _emitTelemetry(
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
            _consultMessages.removeWhere((candidate) =>
                candidate.id == optimisticMessage.id ||
                candidate.clientKey == clientKey);
          });
          _traceMessageList('optimistic.remove', {'clientKey': clientKey});
        }
        _upsertConsultMessage(_VetChatMessage.fromJson(message));
      }
      if (mounted) unawaited(HapticFeedback.lightImpact());
    } catch (error) {
      if (error is _VetUploadCanceledException) {
        await _VetOutboxStore.remove(clientKey);
        _uploadCancelTokens.remove(clientKey);
        if (mounted) {
          setState(() {
            _consultMessages.removeWhere((candidate) =>
                candidate.id == optimisticMessage.id ||
                candidate.clientKey == clientKey);
          });
          _announceForAccessibility('Carga cancelada.');
        }
        return;
      }
      final errorCode = _telemetryErrorCode(error);
      final attempts = outboxEntry.attempts + 1;
      final retryable = _isRetryableVetErrorCode(errorCode);
      final nextRetryAt = retryable ? _nextVetRetryAt(attempts) : null;
      await _VetOutboxStore.upsert(outboxEntry.copyWith(
        status: retryable ? 'queued' : 'failed',
        attempts: attempts,
        lastError: error.toString(),
        lastErrorCode: errorCode,
        nextRetryAt: nextRetryAt,
        updatedAt: DateTime.now(),
      ));
      if (retryable && nextRetryAt != null) {
        _scheduleVetOutboxRetry(nextRetryAt);
      }
      _emitTelemetry(
        'send_failed',
        clientKey: clientKey,
        durationMs: DateTime.now().difference(sendStartedAt).inMilliseconds,
        errorCode: errorCode,
        metadata: {'attachmentCount': pendingAttachments.length},
      );
      if (!mounted) return;
      unawaited(HapticFeedback.mediumImpact());
      _announceForAccessibility('No se pudo enviar el mensaje.');
      setState(() {
        final failedMessage = outboxEntry
            .copyWith(
              status: 'failed',
              attempts: outboxEntry.attempts + 1,
              lastError: error.toString(),
              lastErrorCode: errorCode,
              nextRetryAt: nextRetryAt,
              updatedAt: DateTime.now(),
            )
            .toMessage();
        final index = _consultMessages.indexWhere((candidate) =>
            candidate.id == optimisticMessage.id ||
            candidate.clientKey == clientKey);
        if (index >= 0) {
          _consultMessages[index] =
              failedMessage.withReceiptFrom(_consultMessages[index]);
        } else {
          _consultMessages.add(failedMessage);
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No se pudo enviar: $error'),
          action: _consultClosed
              ? null
              : SnackBarAction(
                  label: 'Reintentar',
                  onPressed: () => unawaited(_sendConsultPayload(
                    text: trimmedText,
                    clearComposer: clearComposer,
                    pendingAttachments: pendingAttachments,
                    clientKeyOverride: clientKey,
                    retrying: true,
                    attemptsOverride: attempts,
                  )),
                ),
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _flushOutbox() async {
    if (_outboxFlushing || _sending || _consultClosed || _isAssistant) return;
    _outboxFlushing = true;
    try {
      final entries = await _VetOutboxStore.entriesForSession(widget.sessionId);
      for (final entry in entries) {
        if (!mounted || _consultClosed) return;
        if (entry.status == 'failed') continue;
        if (!entry.retryDue) {
          final nextRetryAt = entry.nextRetryAt;
          if (nextRetryAt != null) _scheduleVetOutboxRetry(nextRetryAt);
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
      _outboxFlushing = false;
    }
  }

  Future<_VetAttachment> _uploadConsultAttachment(
    _PendingVetAttachment attachment, {
    required String clientKey,
  }) async {
    final response = await _postGatewayJson(
      '/sessions/${Uri.encodeComponent(widget.sessionId)}/attachments/upload-url',
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
      throw const _VetChatException(
          'No pude preparar el archivo para subirlo.');
    }
    final attachmentId = attachmentJson['id']?.toString();
    final uploadStartedAt = DateTime.now();
    final cancelToken =
        _uploadCancelTokens.putIfAbsent(clientKey, _VetUploadCancelToken.new);
    _emitTelemetry('upload_started',
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
          _updateVetAttachmentUploadProgress(
              clientKey, attachment.path, progress);
          final percent = (progress * 100).round();
          if (percent == 25 ||
              percent == 50 ||
              percent == 75 ||
              percent == 100) {
            _emitTelemetry('upload_progress',
                clientKey: clientKey,
                attachmentId: attachmentId,
                valueCount: percent,
                metadata: {'progressPercent': percent});
          }
        },
      );
      _emitTelemetry('upload_completed',
          clientKey: clientKey,
          attachmentId: attachmentId,
          durationMs: DateTime.now().difference(uploadStartedAt).inMilliseconds,
          valueCount: attachment.byteSize,
          metadata: {'attachmentKind': attachment.kind.name});
      _uploadCancelTokens.remove(clientKey);
    } catch (error) {
      if (error is _VetUploadCanceledException) rethrow;
      _emitTelemetry('upload_failed',
          clientKey: clientKey,
          attachmentId: attachmentId,
          durationMs: DateTime.now().difference(uploadStartedAt).inMilliseconds,
          valueCount: attachment.byteSize,
          errorCode: _telemetryErrorCode(error),
          metadata: {'attachmentKind': attachment.kind.name});
      _announceForAccessibility('No se pudo subir el archivo.');
      rethrow;
    } finally {
      if (cancelToken.canceled) _uploadCancelTokens.remove(clientKey);
    }
    return _VetAttachment.fromJson(attachmentJson);
  }

  Future<void> _uploadFileToSignedUrlWithProgress({
    required String bucket,
    required String path,
    required String token,
    required File file,
    required String fileName,
    required String contentType,
    required _VetUploadCancelToken cancelToken,
    required ValueChanged<double> onProgress,
  }) async {
    final totalBytes = await file.length();
    if (totalBytes <= 0) {
      throw const _VetChatException('El archivo está vacío.');
    }
    onProgress(0);
    final boundary = '----cav-${DateTime.now().microsecondsSinceEpoch}';
    final uri =
        _signedStorageUploadUri(bucket: bucket, path: path, token: token);
    final client = HttpClient();
    try {
      if (cancelToken.canceled) throw const _VetUploadCanceledException();
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
          throw const _VetUploadCanceledException();
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
        throw const _VetUploadCanceledException();
      }
      final uploadResponse = await request.close();
      final body = await utf8.decoder.bind(uploadResponse).join();
      if (uploadResponse.statusCode < 200 || uploadResponse.statusCode >= 300) {
        throw _VetChatException(body.isEmpty
            ? 'No pude subir el archivo.'
            : 'No pude subir el archivo: $body');
      }
      onProgress(1);
    } finally {
      client.close(force: true);
    }
  }

  void _cancelUpload(String clientKey) {
    _uploadCancelTokens[clientKey]?.cancel();
  }

  Future<void> _retryFailedMessage(String clientKey) async {
    if (_isAssistant || _consultClosed) return;
    final entries = await _VetOutboxStore.entriesForSession(widget.sessionId);
    _VetOutboxEntry? entry;
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

  bool _isRetryableVetErrorCode(String code) => !{
        'auth',
        'too_large',
        'unsupported_media',
        'session_closed'
      }.contains(code);

  DateTime _nextVetRetryAt(int attempts) {
    final seconds = math.min(60, math.pow(2, math.min(attempts, 6)).toInt());
    return DateTime.now().add(
        Duration(seconds: seconds, milliseconds: math.Random().nextInt(750)));
  }

  void _scheduleVetOutboxRetry(DateTime nextRetryAt) {
    final delay = nextRetryAt.difference(DateTime.now());
    unawaited(Future<void>.delayed(
      delay.isNegative ? Duration.zero : delay,
      () async {
        if (!mounted || _consultClosed || _isAssistant) return;
        await _flushOutbox();
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

  void _updateVetAttachmentUploadProgress(
      String clientKey, String localPath, double progress) {
    if (!mounted) return;
    setState(() {
      final messageIndex = _consultMessages.indexWhere(
        (message) => message.clientKey == clientKey || message.id == clientKey,
      );
      if (messageIndex < 0) return;
      final message = _consultMessages[messageIndex];
      _consultMessages[messageIndex] = message.copyWith(
        attachments: message.attachments
            .map((attachment) =>
                attachment.localPath == localPath || attachment.id == localPath
                    ? attachment.copyWith(uploadProgress: progress)
                    : attachment)
            .toList(growable: false),
      );
    });
  }

  Future<_VetAttachment?> _refreshVetAttachmentDownloadUrl(
      _VetAttachment attachment) async {
    final startedAt = DateTime.now();
    try {
      final response = await _getGatewayJson(
        '/sessions/${Uri.encodeComponent(widget.sessionId)}/attachments/${Uri.encodeComponent(attachment.id)}/download-url',
      );
      final attachmentJson = _asMap(response['attachment']);
      if (attachmentJson == null) return null;
      _emitTelemetry(
        'playback_refresh',
        attachmentId: attachment.id,
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
        metadata: {
          'playbackKind': attachment.kind.name,
          'status': 'success',
        },
      );
      return _VetAttachment.fromJson(attachmentJson);
    } catch (error) {
      _emitTelemetry(
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

  void _emitTelemetry(
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
    if (_isAssistant || widget.sessionId.trim().isEmpty) return;
    unawaited(_postGatewayJson(
      '/sessions/${Uri.encodeComponent(widget.sessionId)}/telemetry',
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

  bool get _canSendConsultMedia =>
      !_isAssistant && !_sending && !_consultClosed && !_endingConsult;

  Future<void> _pickConsultMedia() async {
    if (!_canSendConsultMedia) return;
    final choice = await showModalBottomSheet<_VetMediaChoice>(
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
              onTap: () => Navigator.of(context).pop(_VetMediaChoice.camera),
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library_rounded, color: Colors.white),
              title:
                  const Text('imágenes', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(context).pop(_VetMediaChoice.images),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_rounded, color: Colors.white),
              title: const Text('video', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(context).pop(_VetMediaChoice.video),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    try {
      if (choice == _VetMediaChoice.camera) {
        final file = await _imagePicker.pickImage(
          source: ImageSource.camera,
          imageQuality: 82,
          maxWidth: 1800,
          maxHeight: 1800,
        );
        if (file == null) return;
        _stageVetAttachments([
          await _pendingAttachmentFromXFile(file, _VetAttachmentKind.image)
        ]);
      } else if (choice == _VetMediaChoice.images) {
        final files = await _imagePicker.pickMultiImage(
          imageQuality: 82,
          maxWidth: 1800,
          maxHeight: 1800,
          limit: 6,
        );
        if (files.isEmpty) return;
        final attachments = <_PendingVetAttachment>[];
        for (final file in files.take(6)) {
          attachments.add(await _pendingAttachmentFromXFile(
              file, _VetAttachmentKind.image));
        }
        _stageVetAttachments(attachments);
      } else {
        final file = await _imagePicker.pickVideo(source: ImageSource.gallery);
        if (file == null) return;
        _stageVetAttachments([
          await _pendingAttachmentFromXFile(file, _VetAttachmentKind.video)
        ]);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo adjuntar: $error')),
      );
    }
  }

  void _stageVetAttachments(List<_PendingVetAttachment> attachments) {
    if (attachments.isEmpty || !mounted) return;
    final beforeCount = _stagedVetAttachments.length;
    setState(() {
      final remaining = math.max(0, 6 - _stagedVetAttachments.length);
      _stagedVetAttachments.addAll(attachments.take(remaining));
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

  void _removeStagedVetAttachment(_PendingVetAttachment attachment) {
    setState(() {
      _stagedVetAttachments.removeWhere((item) => item.path == attachment.path);
    });
    _announceForAccessibility('Archivo adjunto eliminado.');
  }

  Future<_PendingVetAttachment> _pendingAttachmentFromXFile(
      XFile file, _VetAttachmentKind kind) async {
    final preparedFile = await _prepareVetMediaFile(file, kind);
    final byteSize = await preparedFile.length();
    final contentType = _vetContentTypeForFile(preparedFile.path, kind);
    _validateVetAttachment(kind, byteSize, null);
    return _PendingVetAttachment(
      kind: kind,
      path: preparedFile.path,
      fileName: preparedFile.name,
      contentType: contentType,
      byteSize: byteSize,
    );
  }

  Future<XFile> _prepareVetMediaFile(
      XFile file, _VetAttachmentKind kind) async {
    if (kind == _VetAttachmentKind.image) {
      return _compressVetImage(file);
    }
    if (kind == _VetAttachmentKind.video) {
      return _compressVetVideo(file);
    }
    return file;
  }

  Future<XFile> _compressVetImage(XFile file) async {
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
      debugPrint(
          '[VetChat] image compression skipped: ${error.runtimeType} $error');
      return file;
    }
  }

  Future<XFile> _compressVetVideo(XFile file) async {
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
      debugPrint(
          '[VetChat] video compression skipped: ${error.runtimeType} $error');
      return file;
    }
  }

  Future<void> _startVoiceRecording() async {
    if (!_canSendConsultMedia || _recordingVoice) return;
    try {
      if (!await _audioRecorder.hasPermission()) {
        throw const _VetChatException(
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
      _validateVetAttachment(_VetAttachmentKind.voice, byteSize, durationMs);
      _stageVetAttachments([
        _PendingVetAttachment(
          kind: _VetAttachmentKind.voice,
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
    _reconnectTimer?.cancel();
    _sendTyping(false);
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
      request.headers.set('x-cav-actor-role', 'vet');
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
      request.headers.set('x-cav-actor-role', 'vet');
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

  void _announceForAccessibility(String message) {
    if (!mounted) return;
    unawaited(SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    ));
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
    final topInset = MediaQuery.paddingOf(context).top;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final topChromeHeight = topInset + 90;
    final topFadeHeight = topInset + 132;
    final bottomFadeHeight = bottomInset + 150;
    final bottomListPadding = bottomInset +
        (_stagedVetAttachments.isNotEmpty || _recordingVoice ? 178 : 126);
    final hasHandoff = _handoffBrief != null || _handoffPending;
    final itemCount = (hasHandoff ? 1 : 0) + _consultMessages.length;
    final messageList = _consultLoading && itemCount == 0
        ? const Center(child: CircularProgressIndicator(color: Colors.white))
        : _consultLoadError != null && itemCount == 0
            ? Padding(
                padding: EdgeInsets.fromLTRB(18, topChromeHeight, 18, 120),
                child: _ChatStatusView(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: 'No pude cargar el chat',
                  message: _consultLoadError.toString(),
                  onRetry: _refreshMessages,
                ),
              )
            : itemCount == 0
                ? Padding(
                    padding: EdgeInsets.fromLTRB(18, topChromeHeight, 18, 120),
                    child: const _ChatStatusView(
                      icon: Icons.forum_outlined,
                      title: 'Chat listo',
                      message: 'Aún no hay mensajes en esta consulta.',
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: EdgeInsets.fromLTRB(
                      18,
                      topChromeHeight,
                      18,
                      bottomListPadding,
                    ),
                    itemCount: itemCount,
                    itemBuilder: (context, index) {
                      if (hasHandoff && index == 0) {
                        return _HandoffBriefCard(
                          handoff: _handoffBrief,
                          pending: _handoffPending,
                        );
                      }
                      final messageIndex = index - (hasHandoff ? 1 : 0);
                      final message = _consultMessages[messageIndex];
                      final nextMessage =
                          messageIndex < _consultMessages.length - 1
                              ? _consultMessages[messageIndex + 1]
                              : null;
                      final showMessageLog = nextMessage == null ||
                          nextMessage.role != message.role ||
                          message.deliveryState == 'failed';
                      return Column(
                        key: ValueKey('thread-${message.id}'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_unreadMarkerMessageId == message.id)
                            const _VetUnreadMessagesMarker(),
                          _ChatBubble(
                            message: message,
                            ownerName: _ownerName,
                            showMessageLog: showMessageLog,
                            onRefreshAttachment:
                                _refreshVetAttachmentDownloadUrl,
                            onCancelUpload: _cancelUpload,
                            onRetryMessage: (clientKey) =>
                                unawaited(_retryFailedMessage(clientKey)),
                          ),
                        ],
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
        if (_showDraftRestoredBanner)
          Positioned(
            left: 18,
            right: 18,
            bottom: bottomInset + 88,
            child: _VetDraftRestoredBanner(onDismiss: _dismissDraftBanner),
          ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: _ChatTopBar(
              sessionId: widget.sessionId,
              ownerOnline: _ownerOnline,
              ownerTyping: _ownerTyping,
              realtimeStatus: _realtimeStatus,
              onBack: () => unawaited(_returnDashboard()),
              onEnd: _consultClosed ? null : () => unawaited(_endConsult()),
              ending: _endingConsult,
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
            sending: _sending || _endingConsult || _consultClosed,
            mediaEnabled: _canSendConsultMedia,
            showMediaControls: !_isAssistant,
            recording: _recordingVoice,
            recordingStartedAt: _recordingStartedAt,
            stagedAttachments: _stagedVetAttachments,
            includeBottomInset: true,
            onSend: _sendMessage,
            onPickMedia: _pickConsultMedia,
            onRemoveAttachment: _removeStagedVetAttachment,
            onMicStart: _startVoiceRecording,
            onMicStop: _stopVoiceRecording,
          ),
        ),
      ],
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
            mediaEnabled: false,
            showMediaControls: false,
            recording: false,
            recordingStartedAt: null,
            stagedAttachments: const [],
            includeBottomInset: true,
            onSend: _sendMessage,
            onPickMedia: () {},
            onRemoveAttachment: (_) {},
            onMicStart: () {},
            onMicStop: ({bool send = true}) async {},
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

class _VetUnreadMessagesMarker extends StatelessWidget {
  const _VetUnreadMessagesMarker();

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

class _VetDraftRestoredBanner extends StatelessWidget {
  const _VetDraftRestoredBanner({required this.onDismiss});

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
        child: Semantics(
          button: true,
          label: 'Volver al panel',
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
    required this.realtimeStatus,
    required this.onBack,
    required this.onEnd,
    required this.ending,
  });

  final String sessionId;
  final bool ownerOnline;
  final bool ownerTyping;
  final String? realtimeStatus;
  final VoidCallback onBack;
  final VoidCallback? onEnd;
  final bool ending;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 24, 18, 0),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: 'Volver al panel',
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
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              realtimeStatus ??
                  (ownerTyping
                      ? 'tutor escribiendo...'
                      : ownerOnline
                          ? 'tutor en línea'
                          : 'consulta activa'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.62),
                fontSize: 12,
                fontFamily: 'ABCDiatype',
              ),
            ),
          ),
          Semantics(
            button: true,
            enabled: !ending && onEnd != null,
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

class _HandoffBriefCard extends StatelessWidget {
  const _HandoffBriefCard({required this.handoff, required this.pending});

  final _VetHandoffBrief? handoff;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final brief = handoff;
    final sections = <Widget>[
      if (brief != null && brief.summaryText.isNotEmpty)
        Text(
          brief.summaryText,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontFamily: 'ABC Diatype',
            height: 1.32,
          ),
        ),
      if (brief != null && brief.redFlags.isNotEmpty)
        _HandoffList(label: 'alertas', items: brief.redFlags),
      if (brief != null && brief.reportedSigns.isNotEmpty)
        _HandoffList(label: 'signos reportados', items: brief.reportedSigns),
      if (brief != null && brief.recommendedFirstChecks.isNotEmpty)
        _HandoffList(
          label: 'primeras revisiones',
          items: brief.recommendedFirstChecks,
        ),
      if (pending && brief == null)
        Text(
          'preparando brief...',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.56),
            fontSize: 13,
            fontFamily: 'ABC Diatype',
            height: 1.28,
          ),
        ),
    ];

    return _HandoffBriefFrame(
      active: pending || brief != null,
      margin: const EdgeInsets.only(bottom: 14),
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
              if (brief != null && brief.urgency.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  brief.urgency,
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

class _HandoffBriefFrame extends StatefulWidget {
  const _HandoffBriefFrame({
    required this.child,
    required this.active,
    required this.margin,
  });

  final Widget child;
  final bool active;
  final EdgeInsetsGeometry margin;

  @override
  State<_HandoffBriefFrame> createState() => _HandoffBriefFrameState();
}

class _HandoffBriefFrameState extends State<_HandoffBriefFrame>
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
  void didUpdateWidget(covariant _HandoffBriefFrame oldWidget) {
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
        return Container(
          width: double.infinity,
          margin: widget.margin,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(18),
          ),
          child: CustomPaint(
            foregroundPainter: _HandoffBriefOutlinePainter(
              progress: _controller.value,
              active: widget.active,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(15, 13, 15, 14),
              child: child,
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

class _HandoffBriefOutlinePainter extends CustomPainter {
  const _HandoffBriefOutlinePainter({
    required this.progress,
    required this.active,
  });

  final double progress;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect =
        RRect.fromRectAndRadius(rect.deflate(0.7), const Radius.circular(18));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = active ? 1.15 : 1;

    if (active) {
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
      paint.color = Colors.white.withValues(alpha: 0.10);
    }

    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant _HandoffBriefOutlinePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.active != active;
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
  const _ChatBubble({
    required this.message,
    this.ownerName = 'tutor',
    this.showMessageLog = true,
    this.onCancelUpload,
    this.onRetryMessage,
    this.onRefreshAttachment,
  });

  final _VetChatMessage message;
  final String ownerName;
  final bool showMessageLog;
  final ValueChanged<String>? onCancelUpload;
  final ValueChanged<String>? onRetryMessage;
  final Future<_VetAttachment?> Function(_VetAttachment attachment)?
      onRefreshAttachment;

  @override
  Widget build(BuildContext context) {
    final isVet = message.role == 'vet';
    final isAi = message.role == 'ai';
    const messageStyle = TextStyle(
      color: Colors.white,
      fontSize: 15,
      fontWeight: FontWeight.w400,
      height: 1.34,
    );
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final widthFactor = isVet ? 0.66 : 0.72;
    final fixedCap = isVet ? 350.0 : 380.0;
    final maxBubbleWidth = math.min(viewportWidth * widthFactor, fixedCap);
    final trimmedContent = message.content.trim();
    final isVoiceOnly = trimmedContent.isEmpty &&
        message.attachments.length == 1 &&
        message.attachments.first.kind == _VetAttachmentKind.voice;
    final isSingleImageOnly = trimmedContent.isEmpty &&
        message.attachments.length == 1 &&
        message.attachments.first.kind == _VetAttachmentKind.image;
    final isEmptyPlaceholder =
        trimmedContent.isEmpty && message.attachments.isEmpty;
    return Align(
      alignment: isVet ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxBubbleWidth),
        margin: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment:
              isVet ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isEmptyPlaceholder)
              if (isVoiceOnly || isSingleImageOnly)
                _VetAttachmentStrip(
                  attachments: message.attachments,
                  clientKey: message.clientKey,
                  onCancelUpload: onCancelUpload,
                  onRefreshAttachment: onRefreshAttachment,
                  flushSingleImage: isSingleImageOnly,
                )
              else
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: isVet ? const Color(0xFF242426) : Colors.black,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(22),
                      topRight: const Radius.circular(22),
                      bottomLeft: Radius.circular(isVet ? 22 : 6),
                      bottomRight: Radius.circular(isVet ? 6 : 22),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 13),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (trimmedContent.isNotEmpty)
                          isAi
                              ? _AiMessageContent(
                                  content: message.content, style: messageStyle)
                              : Text(message.content, style: messageStyle),
                        if (message.attachments.isNotEmpty) ...[
                          if (trimmedContent.isNotEmpty)
                            const SizedBox(height: 10),
                          _VetAttachmentStrip(
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
                message.label(ownerName: ownerName).isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                message.label(ownerName: ownerName),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.38),
                  fontSize: 10,
                  fontFamily: 'ABCDiatype',
                ),
              ),
            ],
            if (isVet &&
                message.deliveryState == 'failed' &&
                message.clientKey != null &&
                onRetryMessage != null) ...[
              const SizedBox(height: 5),
              TextButton.icon(
                onPressed: () => onRetryMessage!(message.clientKey!),
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
          ],
        ),
      ),
    );
  }
}

class _VetAttachmentStrip extends StatefulWidget {
  const _VetAttachmentStrip({
    required this.attachments,
    required this.clientKey,
    required this.onCancelUpload,
    this.flushSingleImage = false,
    this.onRefreshAttachment,
  });

  final List<_VetAttachment> attachments;
  final String? clientKey;
  final ValueChanged<String>? onCancelUpload;
  final bool flushSingleImage;
  final Future<_VetAttachment?> Function(_VetAttachment attachment)?
      onRefreshAttachment;

  @override
  State<_VetAttachmentStrip> createState() => _VetAttachmentStripState();
}

class _VetAttachmentStripState extends State<_VetAttachmentStrip> {
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
  void didUpdateWidget(covariant _VetAttachmentStrip oldWidget) {
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
            attachment.kind == _VetAttachmentKind.image &&
            attachment.localPath == null)
        .map(_vetDisplayImageUrl)
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
                  child: _VetAttachmentPreview(
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

String? _vetDisplayImageUrl(_VetAttachment attachment) {
  return _vetNonEmpty(attachment.thumbnailUrl) ??
      _vetNonEmpty(attachment.downloadUrl);
}

Widget _fadeInImageFrame(
  BuildContext context,
  Widget child,
  int? frame,
  bool wasSynchronouslyLoaded,
) {
  if (wasSynchronouslyLoaded) return child;
  return AnimatedOpacity(
    opacity: frame == null ? 0 : 1,
    duration: const Duration(milliseconds: 180),
    curve: Curves.easeOutCubic,
    child: child,
  );
}

class _VetAttachmentPreview extends StatelessWidget {
  const _VetAttachmentPreview({
    required this.attachment,
    required this.clientKey,
    required this.onCancelUpload,
    this.flushImage = false,
    this.onRefreshAttachment,
  });

  final _VetAttachment attachment;
  final String? clientKey;
  final ValueChanged<String>? onCancelUpload;
  final bool flushImage;
  final Future<_VetAttachment?> Function(_VetAttachment attachment)?
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
    final displayUrl = _vetDisplayImageUrl(attachment);
    final localPath = attachment.localPath;
    final label = switch (attachment.kind) {
      _VetAttachmentKind.image => 'Imagen',
      _VetAttachmentKind.video => 'Video',
      _VetAttachmentKind.voice => 'Nota de voz',
    };
    if (attachment.kind == _VetAttachmentKind.image &&
        (displayUrl != null || localPath != null)) {
      final image = localPath != null
          ? Image.file(
              File(localPath),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              frameBuilder: _fadeInImageFrame,
            )
          : Image.network(
              displayUrl!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              frameBuilder: _fadeInImageFrame,
            );
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
                  _VetAttachmentUploadOverlay(
                    attachment: attachment,
                    onCancel: clientKey == null || onCancelUpload == null
                        ? null
                        : () => onCancelUpload!(clientKey!),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (attachment.kind == _VetAttachmentKind.voice) {
      return _VetVoiceNoteBubble(
        attachment: attachment,
        onRefreshAttachment: onRefreshAttachment,
      );
    }
    if (attachment.kind == _VetAttachmentKind.video) {
      return _VetVideoBubble(
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
            attachment.kind == _VetAttachmentKind.image
                ? Icons.image_rounded
                : attachment.kind == _VetAttachmentKind.voice
                    ? Icons.mic_rounded
                    : Icons.play_arrow_rounded,
            color: Colors.white,
            size: 19,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              attachment.isUploading
                  ? 'Cargando ${label.toLowerCase()}'
                  : _vetAttachmentLabel(label, attachment),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w500,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
    return attachment.kind == _VetAttachmentKind.image
        ? GestureDetector(onTap: () => _openImage(context), child: bubble)
        : bubble;
  }
}

class _VetAttachmentUploadOverlay extends StatelessWidget {
  const _VetAttachmentUploadOverlay({required this.attachment, this.onCancel});

  final _VetAttachment attachment;
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

class _VetVoiceNoteBubble extends StatefulWidget {
  const _VetVoiceNoteBubble({
    required this.attachment,
    this.onRefreshAttachment,
  });

  final _VetAttachment attachment;
  final Future<_VetAttachment?> Function(_VetAttachment attachment)?
      onRefreshAttachment;

  @override
  State<_VetVoiceNoteBubble> createState() => _VetVoiceNoteBubbleState();
}

class _VetVoiceNoteBubbleState extends State<_VetVoiceNoteBubble> {
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
    _activeVetVoiceNoteId.addListener(_handleActiveVoiceChanged);
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
        if (_activeVetVoiceNoteId.value == widget.attachment.id) {
          _activeVetVoiceNoteId.value = null;
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
  void didUpdateWidget(covariant _VetVoiceNoteBubble oldWidget) {
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
    _activeVetVoiceNoteId.removeListener(_handleActiveVoiceChanged);
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _handleActiveVoiceChanged() {
    if (_activeVetVoiceNoteId.value != widget.attachment.id &&
        _player.playing) {
      unawaited(_player.pause());
    }
  }

  Future<void> _togglePlayback() async {
    if (_loading) return;
    if (_player.playing) {
      await _player.pause();
      return;
    }
    final source = widget.attachment.localPath ?? _downloadUrl;
    if (source == null || source.isEmpty) return;
    _activeVetVoiceNoteId.value = widget.attachment.id;
    if (!_loaded || _failed) {
      setState(() {
        _loading = true;
        _failed = false;
      });
      try {
        if (widget.attachment.localPath != null) {
          await _player.setFilePath(widget.attachment.localPath!);
        } else {
          await _player.setUrl(source);
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
        ? _formatVetVoiceDuration(_position)
        : _formatVetVoiceDuration(displayDuration);
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
                _VetVoiceWaveform(id: widget.attachment.id, progress: progress),
                const SizedBox(height: 4),
                Text(
                  _failed
                      ? 'Toca para reintentar'
                      : widget.attachment.isUploading
                          ? _vetUploadProgressText(widget.attachment)
                          : durationText,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 11,
                    fontFamily: 'ABC Diatype',
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

class _VetVideoBubble extends StatefulWidget {
  const _VetVideoBubble({
    required this.attachment,
    this.onRefreshAttachment,
  });

  final _VetAttachment attachment;
  final Future<_VetAttachment?> Function(_VetAttachment attachment)?
      onRefreshAttachment;

  @override
  State<_VetVideoBubble> createState() => _VetVideoBubbleState();
}

class _VetVideoBubbleState extends State<_VetVideoBubble> {
  VideoPlayerController? _controller;
  bool _loading = false;
  bool _failed = false;
  String? _downloadUrl;

  @override
  void initState() {
    super.initState();
    _downloadUrl = widget.attachment.downloadUrl;
    _activeVetVideoId.addListener(_handleActiveVideoChanged);
  }

  @override
  void didUpdateWidget(covariant _VetVideoBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.id != widget.attachment.id ||
        oldWidget.attachment.downloadUrl != widget.attachment.downloadUrl) {
      _downloadUrl = widget.attachment.downloadUrl;
      _failed = false;
      _disposeController();
    }
  }

  @override
  void dispose() {
    _activeVetVideoId.removeListener(_handleActiveVideoChanged);
    if (_activeVetVideoId.value == widget.attachment.id) {
      _activeVetVideoId.value = null;
    }
    _disposeController();
    super.dispose();
  }

  void _handleActiveVideoChanged() {
    if (_activeVetVideoId.value != widget.attachment.id &&
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
        _activeVetVideoId.value == widget.attachment.id) {
      _activeVetVideoId.value = null;
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
    if (_loading || widget.attachment.isUploading) return;
    var controller = _controller;
    if (controller == null || !controller.value.isInitialized || _failed) {
      await _initializeVideo();
      controller = _controller;
      if (controller == null || !controller.value.isInitialized) return;
    }
    if (controller.value.isPlaying) {
      await controller.pause();
      if (_activeVetVideoId.value == widget.attachment.id) {
        _activeVetVideoId.value = null;
      }
      return;
    }
    _activeVetVideoId.value = widget.attachment.id;
    await controller.play();
  }

  Future<void> _initializeVideo() async {
    final source = _downloadUrl;
    if (source == null || source.isEmpty) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      await _openVideoSource(source);
    } catch (_) {
      if (await _refreshDownloadUrl()) {
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
    final controller = VideoPlayerController.networkUrl(Uri.parse(source));
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
            ? _vetUploadProgressText(widget.attachment)
            : duration.inMilliseconds > 0
                ? '${_formatVetVoiceDuration(position)} / ${_formatVetVoiceDuration(duration)}'
                : _vetAttachmentLabel('Video', widget.attachment);
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
            enabled: !_loading && !widget.attachment.isUploading,
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
                                value: widget.attachment.isUploading
                                    ? widget.attachment.uploadProgress
                                        .clamp(0, 1)
                                    : progress,
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
                                fontFamily: 'ABC Diatype',
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

class _VetVoiceWaveform extends StatelessWidget {
  const _VetVoiceWaveform({required this.id, required this.progress});

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
  final List<_PendingVetAttachment> stagedAttachments;
  final bool includeBottomInset;
  final VoidCallback onSend;
  final VoidCallback onPickMedia;
  final ValueChanged<_PendingVetAttachment> onRemoveAttachment;
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
                          hintText: recording
                              ? _formatRecordingElapsed(recordingStartedAt)
                              : sending
                                  ? 'Pensando...'
                                  : 'escribir mensaje...',
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
                            icon: sending
                                ? const SizedBox(
                                    width: 15,
                                    height: 15,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.black,
                                    ),
                                  )
                                : const Icon(Icons.arrow_upward_rounded,
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

class _ComposerAttachmentTray extends StatelessWidget {
  const _ComposerAttachmentTray({
    required this.attachments,
    required this.sending,
    required this.onRemove,
  });

  final List<_PendingVetAttachment> attachments;
  final bool sending;
  final ValueChanged<_PendingVetAttachment> onRemove;

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

  final _PendingVetAttachment attachment;
  final bool sending;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final isImage = attachment.kind == _VetAttachmentKind.image;
    final isVoice = attachment.kind == _VetAttachmentKind.voice;
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
              ? _VetVoiceNoteBubble(
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
      this.attachments = const [],
      this.deliveredByOther = false,
      this.readByOther = false,
      this.deliveryState});

  factory _VetChatMessage.fromJson(Map<String, dynamic> json) {
    return _VetChatMessage(
      id: json['id']?.toString() ?? '',
      senderId: json['sender_id']?.toString(),
      role: json['role']?.toString().toLowerCase() ?? 'user',
      content: json['content']?.toString() ?? '',
      createdAt: _parseDateTime(json['created_at']),
      clientKey: json['client_key']?.toString(),
      streamOrder: _asInt(json['stream_order']),
      attachments: (_asList(json['attachments']) ?? const [])
          .map(_asMap)
          .whereType<Map<String, dynamic>>()
          .map(_VetAttachment.fromJson)
          .toList(growable: false),
    );
  }

  factory _VetChatMessage.local({
    required String role,
    required String content,
    String? id,
    String? clientKey,
    String? deliveryState,
    List<_VetAttachment> attachments = const [],
  }) {
    return _VetChatMessage(
      id: id ?? _nextVetAssistantMessageId(),
      senderId: Supabase.instance.client.auth.currentUser?.id,
      role: role,
      content: content,
      createdAt: DateTime.now(),
      clientKey: clientKey,
      streamOrder: null,
      attachments: attachments,
      deliveryState: deliveryState,
    );
  }

  final String id;
  final String? senderId;
  final String role;
  final String content;
  final DateTime? createdAt;
  final String? clientKey;
  final int? streamOrder;
  final List<_VetAttachment> attachments;
  final bool deliveredByOther;
  final bool readByOther;
  final String? deliveryState;

  _VetChatMessage copyWith({
    bool? deliveredByOther,
    bool? readByOther,
    List<_VetAttachment>? attachments,
    String? deliveryState,
  }) {
    return _VetChatMessage(
      id: id,
      senderId: senderId,
      role: role,
      content: content,
      createdAt: createdAt,
      clientKey: clientKey,
      streamOrder: streamOrder,
      attachments: attachments ?? this.attachments,
      deliveredByOther: deliveredByOther ?? this.deliveredByOther,
      readByOther: readByOther ?? this.readByOther,
      deliveryState: deliveryState ?? this.deliveryState,
    );
  }

  _VetChatMessage withReceiptFrom(_VetChatMessage previous) {
    return copyWith(
      deliveredByOther: previous.deliveredByOther,
      readByOther: previous.readByOther,
      attachments: _mergeVetAttachments(attachments, previous.attachments),
    );
  }

  String label({String ownerName = 'tutor'}) {
    if (streamOrder == null && role == 'vet') {
      return switch (deliveryState) {
        'failed' => 'Failed',
        'retrying' => 'Retrying...',
        'queued' => 'Queued',
        'sending' => 'Sending...',
        _ => '',
      };
    }
    final ownerLabel = ownerName.trim().isEmpty ? 'tutor' : ownerName.trim();
    if (role == 'vet') {
      final receipt = readByOther
          ? 'Read'
          : deliveredByOther
              ? 'Delivered'
              : null;
      if (createdAt == null) return receipt ?? '';
      final hour = createdAt!.hour.toString().padLeft(2, '0');
      final minute = createdAt!.minute.toString().padLeft(2, '0');
      return receipt == null ? '$hour:$minute' : '$hour:$minute · $receipt';
    }
    final who = role == 'ai' ? 'asistente' : ownerLabel;
    if (createdAt == null) return who;
    final hour = createdAt!.hour.toString().padLeft(2, '0');
    final minute = createdAt!.minute.toString().padLeft(2, '0');
    return '$who · $hour:$minute';
  }
}

enum _VetAttachmentKind { image, video, voice }

enum _VetMediaChoice { camera, images, video }

class _PendingVetAttachment {
  const _PendingVetAttachment({
    required this.kind,
    required this.path,
    required this.fileName,
    required this.contentType,
    required this.byteSize,
    this.durationMs,
  });

  final _VetAttachmentKind kind;
  final String path;
  final String fileName;
  final String contentType;
  final int byteSize;
  final int? durationMs;

  factory _PendingVetAttachment.fromJson(Map<String, dynamic> json) {
    final kindRaw = json['kind']?.toString().toLowerCase();
    final kind = switch (kindRaw) {
      'video' => _VetAttachmentKind.video,
      'voice' => _VetAttachmentKind.voice,
      _ => _VetAttachmentKind.image,
    };
    return _PendingVetAttachment(
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

  _VetAttachment toPreviewAttachment() => _VetAttachment(
        id: path,
        kind: kind,
        contentType: contentType,
        byteSize: byteSize,
        durationMs: durationMs,
        localPath: path,
        status: 'uploading',
        uploadProgress: 0,
      );

  _VetAttachment toComposerAttachment() => _VetAttachment(
        id: path,
        kind: kind,
        contentType: contentType,
        byteSize: byteSize,
        durationMs: durationMs,
        localPath: path,
      );
}

class _VetOutboxEntry {
  const _VetOutboxEntry({
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
  final List<_PendingVetAttachment> attachments;
  final String status;
  final int attempts;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? lastError;
  final String? lastErrorCode;
  final DateTime? nextRetryAt;

  bool get retryDue =>
      nextRetryAt == null || !nextRetryAt!.isAfter(DateTime.now());

  factory _VetOutboxEntry.fromJson(Map<String, dynamic> json) {
    return _VetOutboxEntry(
      sessionId: json['sessionId']?.toString() ?? '',
      clientKey: json['clientKey']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      attachments: (_asList(json['attachments']) ?? const [])
          .map(_asMap)
          .whereType<Map<String, dynamic>>()
          .map(_PendingVetAttachment.fromJson)
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

  _VetOutboxEntry copyWith({
    String? status,
    int? attempts,
    DateTime? updatedAt,
    String? lastError,
    String? lastErrorCode,
    DateTime? nextRetryAt,
  }) {
    return _VetOutboxEntry(
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

  _VetChatMessage toMessage() => _VetChatMessage.local(
        role: 'vet',
        content: text,
        id: clientKey,
        clientKey: clientKey,
        deliveryState: status,
        attachments: attachments
            .map((attachment) => attachment.toPreviewAttachment())
            .toList(growable: false),
      );
}

class _VetOutboxStore {
  static const _fileName = 'vet_consult_chat_outbox.json';

  static Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File('${directory.path}/$_fileName');
  }

  static Future<List<_VetOutboxEntry>> _readAll() async {
    try {
      final file = await _file();
      if (!await file.exists()) return <_VetOutboxEntry>[];
      final decoded = jsonDecode(await file.readAsString());
      return (_asList(decoded) ?? const [])
          .map(_asMap)
          .whereType<Map<String, dynamic>>()
          .map(_VetOutboxEntry.fromJson)
          .where((entry) =>
              entry.sessionId.isNotEmpty && entry.clientKey.isNotEmpty)
          .toList(growable: true);
    } catch (_) {
      return <_VetOutboxEntry>[];
    }
  }

  static Future<void> _writeAll(List<_VetOutboxEntry> entries) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(
        entries.map((entry) => entry.toJson()).toList(growable: false)));
  }

  static Future<List<_VetOutboxEntry>> entriesForSession(
      String sessionId) async {
    final entries = await _readAll();
    return entries
        .where((entry) => entry.sessionId == sessionId)
        .toList(growable: false)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  static Future<void> upsert(_VetOutboxEntry entry) async {
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

class _VetDraftStore {
  static const _fileName = 'vet_consult_chat_drafts.json';

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
    if (draft.trim().isEmpty) {
      drafts.remove(sessionId);
    } else {
      drafts[sessionId] = draft;
    }
    await _writeAll(drafts);
  }

  static Future<void> clear(String sessionId) => save(sessionId, '');
}

class _VetAttachment {
  const _VetAttachment({
    required this.id,
    required this.kind,
    required this.contentType,
    required this.byteSize,
    this.durationMs,
    this.downloadUrl,
    this.thumbnailUrl,
    this.localPath,
    this.status,
    this.uploadProgress = 0,
  });

  factory _VetAttachment.fromJson(Map<String, dynamic> json) {
    final kindRaw = json['kind']?.toString().toLowerCase();
    final kind = switch (kindRaw) {
      'video' => _VetAttachmentKind.video,
      'voice' => _VetAttachmentKind.voice,
      _ => _VetAttachmentKind.image,
    };
    return _VetAttachment(
      id: json['id']?.toString() ?? _nextVetAssistantMessageId(),
      kind: kind,
      contentType: json['contentType']?.toString() ??
          json['content_type']?.toString() ??
          '',
      byteSize: _asInt(json['byteSize'] ?? json['byte_size']) ?? 0,
      durationMs: _asInt(json['durationMs'] ?? json['duration_ms']),
      downloadUrl:
          json['downloadUrl']?.toString() ?? json['download_url']?.toString(),
      thumbnailUrl:
          json['thumbnailUrl']?.toString() ?? json['thumbnail_url']?.toString(),
      uploadProgress: _asDouble(json['uploadProgress']) ?? 0,
    );
  }

  final String id;
  final _VetAttachmentKind kind;
  final String contentType;
  final int byteSize;
  final int? durationMs;
  final String? downloadUrl;
  final String? thumbnailUrl;
  final String? localPath;
  final String? status;
  final double uploadProgress;

  bool get isUploading => status == 'uploading';

  _VetAttachment copyWith({
    String? status,
    double? uploadProgress,
  }) {
    return _VetAttachment(
      id: id,
      kind: kind,
      contentType: contentType,
      byteSize: byteSize,
      durationMs: durationMs,
      downloadUrl: downloadUrl,
      thumbnailUrl: thumbnailUrl,
      localPath: localPath,
      status: status ?? this.status,
      uploadProgress: uploadProgress ?? this.uploadProgress,
    );
  }

  _VetAttachment withMediaFrom(_VetAttachment previous) {
    return _VetAttachment(
      id: id,
      kind: kind,
      contentType: contentType,
      byteSize: byteSize,
      durationMs: durationMs ?? previous.durationMs,
      downloadUrl:
          _vetNonEmpty(downloadUrl) ?? _vetNonEmpty(previous.downloadUrl),
      thumbnailUrl:
          _vetNonEmpty(thumbnailUrl) ?? _vetNonEmpty(previous.thumbnailUrl),
      localPath: _vetNonEmpty(localPath) ?? _vetNonEmpty(previous.localPath),
      status: status ?? previous.status,
      uploadProgress:
          uploadProgress > 0 ? uploadProgress : previous.uploadProgress,
    );
  }
}

List<_VetAttachment>? _mergeVetAttachments(
    List<_VetAttachment> current, List<_VetAttachment> previous) {
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
    if (next.downloadUrl != attachment.downloadUrl ||
        next.thumbnailUrl != attachment.thumbnailUrl ||
        next.localPath != attachment.localPath ||
        next.uploadProgress != attachment.uploadProgress) {
      changed = true;
    }
    return next;
  }).toList(growable: false);
  return changed ? merged : null;
}

String? _vetNonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : value;
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

double? _asDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
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

String _vetContentTypeForFile(String path, _VetAttachmentKind kind) {
  final lower = path.toLowerCase();
  if (kind == _VetAttachmentKind.voice) return 'audio/mp4';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'image/heic';
  if (lower.endsWith('.mov')) return 'video/quicktime';
  if (lower.endsWith('.webm')) return 'video/webm';
  if (kind == _VetAttachmentKind.video) return 'video/mp4';
  return 'image/jpeg';
}

void _validateVetAttachment(
    _VetAttachmentKind kind, int byteSize, int? durationMs) {
  final maxBytes = switch (kind) {
    _VetAttachmentKind.image => 8 * 1024 * 1024,
    _VetAttachmentKind.video => 50 * 1024 * 1024,
    _VetAttachmentKind.voice => 15 * 1024 * 1024,
  };
  if (byteSize > maxBytes) {
    throw const _VetChatException(
        'El archivo es demasiado grande para enviarlo.');
  }
  if (kind == _VetAttachmentKind.voice &&
      durationMs != null &&
      durationMs > 300000) {
    throw const _VetChatException(
        'La nota de voz no puede pasar de 5 minutos.');
  }
}

String _vetAttachmentLabel(String label, _VetAttachment attachment) {
  final duration = attachment.durationMs;
  if (duration == null || duration <= 0) return label;
  return '$label · ${_formatVetVoiceDuration(Duration(milliseconds: duration))}';
}

String _vetUploadProgressText(_VetAttachment attachment) {
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

String _formatVetVoiceDuration(Duration duration) {
  final seconds = duration.inSeconds;
  final minutes = seconds ~/ 60;
  final rest = (seconds % 60).toString().padLeft(2, '0');
  return '$minutes:$rest';
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

class _VetUploadCanceledException implements Exception {
  const _VetUploadCanceledException();

  @override
  String toString() => 'upload_canceled';
}

class _VetUploadCancelToken {
  bool _canceled = false;

  bool get canceled => _canceled;

  void cancel() {
    _canceled = true;
  }
}
