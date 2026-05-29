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
int _chatMessageSequence = 0;

String _nextChatMessageId() {
  _chatMessageSequence += 1;
  return '${DateTime.now().microsecondsSinceEpoch}-$_chatMessageSequence';
}

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

  Future<void> _activateService(String service, _AiChatTurnResult result, {bool addUserBubble = true}) async {
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
        _messages.add(_ChatMessage.user(kind == 'video' ? 'Iniciar videollamada ahora.' : 'Iniciar chat con el veterinario.'));
      }
      _isSending = true;
    });
    _scrollToBottom();

    try {
      final start = await _startSession(kind, result);
      _aiChatLog('activateService /sessions/start response keys=${start.keys.join(',')}');
      if (start['overage'] == true) {
        final exhaustedResult = result.withEntitlement(
          serviceType: kind,
          canUse: false,
          remaining: 0,
          reason: start['overageReason']?.toString(),
        );
        final offerMessage = await _aiEntitlementOfferMessage(kind, start, exhaustedResult);
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
        _messages.add(_ChatMessage.assistant(_friendlyError(error), includeInHistory: false));
        _isSending = false;
      });
      _scrollToBottom();
    }
  }

  Future<void> _purchaseSingleSession(String service, _AiChatTurnResult result) async {
    if (_isSending) {
      _aiChatLog('purchaseSingleSession ignored while busy service=$service');
      return;
    }
    final kind = service == 'video' || service == 'scheduled_video' ? 'video' : 'chat';
    _aiChatLog('purchaseSingleSession start kind=$kind');
    setState(() {
      _messages.add(_ChatMessage.user(kind == 'video' ? 'Comprar videollamada única.' : 'Comprar chat único.'));
      _isSending = true;
    });
    _scrollToBottom();

    try {
      final grant = await _postGatewayJson('/subscriptions/overage/dev-grant', {
        'type': kind,
        'quantity': 1,
      });
      _aiChatLog('purchaseSingleSession dev grant response keys=${grant.keys.join(',')}');
      final start = await _startSession(kind, result);
      if (start['overage'] == true) {
        if (!mounted) return;
        setState(() {
          _messages.add(_ChatMessage.assistant(
            _paymentRequiredMessage(start),
            result: result.withEntitlement(serviceType: kind, canUse: false, remaining: 0, reason: start['overageReason']?.toString()),
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
        _messages.add(_ChatMessage.assistant(_friendlyError(error), includeInHistory: false));
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
      final option = await _fetchSubscriptionUpgradeOption(result.commerceService);
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
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage.assistant(_friendlyError(error), includeInHistory: false));
        _isSending = false;
      });
      _scrollToBottom();
    }
  }

  Future<void> _confirmSubscriptionUpgrade(_ChatSubscriptionPlan plan, _AiChatTurnResult result) async {
    if (_isSending) return;
    _aiChatLog('confirmSubscriptionUpgrade start plan=${plan.code} service=${result.commerceService}');
    setState(() {
      _messages.add(_ChatMessage.user('Actualizar a ${plan.displayName}.'));
      _isSending = true;
    });
    _scrollToBottom();

    try {
      var upgrade = await _postGatewayJson('/subscriptions/change-plan', {'code': plan.code});
      if (upgrade['ok'] != true && upgrade['reason']?.toString() == 'no_active_subscription') {
        upgrade = await _postGatewayJson('/subscriptions/activate-plan', {'code': plan.code});
      }
      if (upgrade['ok'] != true) {
        throw _ChatApiException('No pude actualizar el plan: ${upgrade['reason']?.toString() ?? 'respuesta inválida'}');
      }

      final message = await _aiUpgradeConfirmedMessage(plan, result);
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage.assistant(message, includeInHistory: false));
        _isSending = false;
      });
      _scrollToBottom();

      if (result.canRetryActivationAfterUpgrade && await _hasServiceAvailability(result.commerceService)) {
        await _activateService(result.commerceService, result, addUserBubble: false);
      } else if (result.canRetryActivationAfterUpgrade) {
        final message = await _aiPostUpgradeStillExhaustedMessage(plan, result);
        if (!mounted) return;
        setState(() {
          _messages.add(_ChatMessage.assistant(
            message,
            result: result.withEntitlement(serviceType: result.commerceService, canUse: false, remaining: 0, reason: 'no_${result.commerceService}_entitlement_left'),
            includeInHistory: false,
          ));
          _isSending = false;
        });
        _scrollToBottom();
      }
    } catch (error) {
      _aiChatLog('confirmSubscriptionUpgrade failed: ${error.runtimeType} $error');
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage.assistant(_friendlyError(error), includeInHistory: false));
        _isSending = false;
      });
      _scrollToBottom();
    }
  }

  Future<_SubscriptionUpgradeOption> _fetchSubscriptionUpgradeOption(String service) async {
    final subscriptions = await _getGatewayJson('/subscriptions/my');
    final usageResponse = await _getGatewayJson('/subscriptions/usage/current');
    final plansResponse = await _getGatewayJson('/plans');
    final usage = _ChatSubscriptionUsage.fromJson(_asMap(usageResponse['usage']) ?? const {});
    final plans = (_asList(plansResponse['items']) ?? const [])
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .map(_ChatSubscriptionPlan.fromJson)
        .where((plan) => plan.code.isNotEmpty && (plan.includedChats > 0 || plan.includedVideos > 0) && !plan.code.endsWith('_unit'))
        .toList();

    plans.sort((a, b) {
      final rank = a.rank.compareTo(b.rank);
      if (rank != 0) return rank;
      final price = a.monthlyCents.compareTo(b.monthlyCents);
      return price != 0 ? price : a.code.compareTo(b.code);
    });
    if (plans.isEmpty) {
      throw const _ChatApiException('No pude cargar los planes disponibles. Inténtalo de nuevo.');
    }

    Map<String, dynamic>? activeRow;
    for (final item in _asList(subscriptions['data']) ?? const []) {
      final row = _asMap(item);
      if (row != null && _truthy(row['is_active_now'])) {
        activeRow = row;
        break;
      }
    }

    final currentCode = _asMap(activeRow?['plan'])?['code']?.toString().toLowerCase();
    final currentPlan = currentCode == null ? null : _findPlanByCode(plans, currentCode);
    final currentIndex = currentPlan == null ? -1 : plans.indexWhere((plan) => plan.code.toLowerCase() == currentPlan.code.toLowerCase());
    final targetPlan = plans.firstWhere(
      (plan) {
        final planIndex = plans.indexWhere((item) => item.code.toLowerCase() == plan.code.toLowerCase());
        if (currentIndex >= 0 && planIndex <= currentIndex) return false;
        if (currentIndex < 0 && currentPlan != null && plan.monthlyCents <= currentPlan.monthlyCents) return false;
        return usage.remainingForPlan(plan, service) > 0;
      },
      orElse: () => const _ChatSubscriptionPlan.empty(),
    );

    if (targetPlan.code.isEmpty) {
      throw const _ChatApiException('No encontré un plan superior que libere disponibilidad para esta consulta en el periodo actual.');
    }

    return _SubscriptionUpgradeOption(currentPlan: currentPlan, targetPlan: targetPlan, usage: usage);
  }

  Future<String> _aiUpgradePlanMessage(_SubscriptionUpgradeOption option, _AiChatTurnResult result) async {
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
      final generated = _AiChatTurnResult.fromJson(response).payload.message.trim();
      if (generated.isNotEmpty) return generated;
    } catch (error) {
      _aiChatLog('aiUpgradePlanMessage fallback after ${error.runtimeType}: $error');
    }
    return '${option.targetPlan.displayName} te da ${option.targetPlan.includedChats} chats y ${option.targetPlan.includedVideos} videollamadas incluidas para tener más margen de atención. Puedes actualizar desde el botón del chat.';
  }

  Future<String> _aiUpgradeConfirmedMessage(_ChatSubscriptionPlan plan, _AiChatTurnResult result) async {
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
      final generated = _AiChatTurnResult.fromJson(response).payload.message.trim();
      if (generated.isNotEmpty) return generated;
    } catch (error) {
      _aiChatLog('aiUpgradeConfirmedMessage fallback after ${error.runtimeType}: $error');
    }
    return 'Tu suscripción se actualizó a ${plan.displayName}; voy a volver a validar la disponibilidad de $service.';
  }

  Future<String> _aiPostUpgradeStillExhaustedMessage(_ChatSubscriptionPlan plan, _AiChatTurnResult result) async {
    final service = result.commerceService == 'video' ? 'videollamadas' : 'chats';
    final prompt = [
      'Contexto interno de Call a Vet: el usuario actualizó a ${plan.displayName}, pero al revalidar aún no quedan $service incluidos disponibles este periodo.',
      'Escribe solo el mensaje visible para el usuario, en español, máximo dos frases.',
      'Explica de forma clara que la actualización se aplicó, pero el cupo del periodo sigue agotado para ese servicio, y ofrece comprar una sesión única o revisar otro plan.',
      'No menciones IDs ni detalles técnicos.',
    ].join(' ');
    try {
      final response = await _runAiTurn(prompt, const []);
      final generated = _AiChatTurnResult.fromJson(response).payload.message.trim();
      if (generated.isNotEmpty) return generated;
    } catch (error) {
      _aiChatLog('aiPostUpgradeStillExhaustedMessage fallback after ${error.runtimeType}: $error');
    }
    return 'La actualización a ${plan.displayName} se aplicó, pero el cupo de $service del periodo sigue agotado. Puedes comprar una sesión única o revisar otro plan desde aquí.';
  }

  Future<bool> _hasServiceAvailability(String service) async {
    final response = await _getGatewayJson('/subscriptions/usage/current');
    final usage = _ChatSubscriptionUsage.fromJson(_asMap(response['usage']) ?? const {});
    return service == 'video' ? usage.remainingVideos > 0 : usage.remainingChats > 0;
  }

  Future<void> _completeStartedSession(String kind, Map<String, dynamic> start) async {
    final sessionId = _uuidOrNull(start['sessionId']?.toString() ?? '');
    if (sessionId == null) {
      throw const _ChatApiException('No pude activar la consulta: el servidor no devolvió una sesión válida.');
    }

    if (kind == 'video') {
      final room = await _createVideoRoom(sessionId);
      final roomName = room['roomName']?.toString() ?? room['roomId']?.toString() ?? sessionId;
      _aiChatLog('completeStartedSession video room created sessionId=$sessionId roomName=$roomName');
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage.assistant('Videollamada activada. Sala: $roomName', includeInHistory: false));
        _isSending = false;
      });
      _scrollToBottom();
      return;
    }

    _aiChatLog('completeStartedSession chat session active sessionId=$sessionId; navigating');
    if (!mounted) return;
    setState(() {
      _messages.add(_ChatMessage.assistant('Chat con veterinario activado. Te llevo a la conversación.', includeInHistory: false));
      _isSending = false;
    });
    _scrollToBottom();
    context.go('/chat/${Uri.encodeComponent(sessionId)}');
  }

  Future<Map<String, dynamic>> _startSession(String kind, _AiChatTurnResult result) {
    return _postGatewayJson('/sessions/start', {
      'kind': kind,
      if (result.petId != null) 'petId': result.petId,
      if (result.vetId != null) 'vetId': result.vetId,
      if (result.specialtyId != null) 'specialtyId': result.specialtyId,
    });
  }

  Future<Map<String, dynamic>> _createVideoRoom(String sessionId) {
    return _postGatewayJson('/video/rooms', {'sessionId': sessionId});
  }

  Future<Map<String, dynamic>> _postGatewayJson(String path, Map<String, dynamic> body) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      throw const _ChatApiException('Tu sesión expiró. Vuelve a iniciar sesión.');
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final startedAt = DateTime.now();
    try {
      final uri = Uri.parse('${Environment.apiBaseUrl}$path');
      _aiChatLog('gateway POST $uri bodyKeys=${body.keys.join(',')}');
      final request = await client.postUrl(uri).timeout(const Duration(seconds: 10));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.add(utf8.encode(jsonEncode(body)));

      final response = await request.close().timeout(const Duration(seconds: 30));
      final rawBody = await utf8.decoder.bind(response).join();
      _aiChatLog(
        'gateway POST $path status=${response.statusCode} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} '
        'bodyPreview="${_preview(rawBody, max: 420)}"',
      );
      final decoded = rawBody.trim().isEmpty ? <String, dynamic>{} : jsonDecode(rawBody);
      final data = _asMap(decoded) ?? <String, dynamic>{};
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _ChatApiException(_errorMessage(data, response.statusCode));
      }
      return data;
    } on TimeoutException {
      throw const _ChatApiException('La conexión tardó demasiado. Inténtalo otra vez.');
    } on FormatException {
      throw const _ChatApiException('El servidor respondió con datos inválidos.');
    } on SocketException {
      throw const _ChatApiException('No hay conexión con Call a Vet en este momento.');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _getGatewayJson(String path) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      throw const _ChatApiException('Tu sesión expiró. Vuelve a iniciar sesión.');
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final startedAt = DateTime.now();
    try {
      final uri = Uri.parse('${Environment.apiBaseUrl}$path');
      _aiChatLog('gateway GET $uri');
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 10));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final response = await request.close().timeout(const Duration(seconds: 30));
      final rawBody = await utf8.decoder.bind(response).join();
      _aiChatLog(
        'gateway GET $path status=${response.statusCode} elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} '
        'bodyPreview="${_preview(rawBody, max: 420)}"',
      );
      final decoded = rawBody.trim().isEmpty ? <String, dynamic>{} : jsonDecode(rawBody);
      final data = _asMap(decoded) ?? <String, dynamic>{};
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _ChatApiException(_errorMessage(data, response.statusCode));
      }
      return data;
    } on TimeoutException {
      throw const _ChatApiException('La conexión tardó demasiado. Inténtalo otra vez.');
    } on FormatException {
      throw const _ChatApiException('El servidor respondió con datos inválidos.');
    } on SocketException {
      throw const _ChatApiException('No hay conexión con Call a Vet en este momento.');
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

  Future<String> _aiEntitlementOfferMessage(String kind, Map<String, dynamic> start, _AiChatTurnResult result) async {
    final service = kind == 'video' ? 'videollamada' : 'chat';
    final reason = start['overageReason']?.toString() ?? result.serviceAccessReason ?? 'no_entitlement';
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
      final generated = _AiChatTurnResult.fromJson(response).payload.message.trim();
      if (generated.isNotEmpty) return generated;
    } catch (error) {
      _aiChatLog('aiEntitlementOfferMessage fallback after ${error.runtimeType}: $error');
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
        child: thread,
      ),
    );
  }

  Widget _buildThread(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final bottomInset = widget.embedded ? 0.0 : MediaQuery.paddingOf(context).bottom;
    final messageList = ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(
        widget.embedded ? 0 : 22,
        widget.embedded ? 10 : topInset + 78,
        widget.embedded ? 0 : 22,
        widget.embedded ? 20 : bottomInset + 102,
      ),
      itemCount: (widget.embedded ? 1 : 0) + _messages.length,
      itemBuilder: (context, index) {
        final introCount = widget.embedded ? 1 : 0;
        if (widget.embedded && index == 0) {
          return const _EmbeddedChatIntro();
        }
        final messageIndex = index - introCount;
        final message = _messages[messageIndex];
        final userTurnsBeforeOrAtMessage = _messages
            .take(messageIndex + 1)
            .where((message) => message.isUser)
            .length;
        return _AnimatedMessageEntry(
          key: ValueKey(message.id),
          isUser: message.isUser,
          child: _MessageBubble(
            message: message,
            embedded: widget.embedded,
            sending: _isSending,
            canShowActions: userTurnsBeforeOrAtMessage >= 2,
            onServiceSelected: _activateService,
            onOneOffPurchaseSelected: _purchaseSingleSession,
            onUpgradeSelected: _openSubscriptionUpgrade,
            onPlanUpgradeConfirmed: _confirmSubscriptionUpgrade,
          ),
        );
      },
    );

    if (widget.embedded) {
      return Column(
        children: [
          Expanded(child: messageList),
          _ChatComposer(
            controller: _inputCtrl,
            focusNode: _focusNode,
            sending: _isSending,
            embedded: true,
            includeBottomInset: false,
            onSend: _sendComposerMessage,
          ),
        ],
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: _MessageOpacityFade(
            topFadeHeight: topInset + 128,
            bottomFadeHeight: bottomInset + 150,
            child: messageList,
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: _ChatHeader(onBack: () => context.go('/home')),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _ChatComposer(
            controller: _inputCtrl,
            focusNode: _focusNode,
            sending: _isSending,
            embedded: false,
            includeBottomInset: true,
            onSend: _sendComposerMessage,
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
        final topStop = (topFadeHeight / bounds.height).clamp(0.12, 0.32).toDouble();
        final bottomStart = (1 - (bottomFadeHeight / bounds.height)).clamp(0.68, 0.90).toDouble();
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

class _EmbeddedChatIntro extends StatelessWidget {
  const _EmbeddedChatIntro();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 28),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
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
      ),
    );
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
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

class _AnimatedMessageEntry extends StatelessWidget {
  const _AnimatedMessageEntry({
    super.key,
    required this.isUser,
    required this.child,
  });

  final bool isUser;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        final slideX = (isUser ? 10.0 : -10.0) * (1 - value);
        final slideY = 5.0 * (1 - value);
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(slideX, slideY),
            child: child,
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
    required this.embedded,
    required this.sending,
    required this.canShowActions,
    required this.onServiceSelected,
    required this.onOneOffPurchaseSelected,
    required this.onUpgradeSelected,
    required this.onPlanUpgradeConfirmed,
  });

  final _ChatMessage message;
  final bool embedded;
  final bool sending;
  final bool canShowActions;
  final void Function(String service, _AiChatTurnResult result) onServiceSelected;
  final void Function(String service, _AiChatTurnResult result) onOneOffPurchaseSelected;
  final void Function(_AiChatTurnResult result) onUpgradeSelected;
  final void Function(_ChatSubscriptionPlan plan, _AiChatTurnResult result) onPlanUpgradeConfirmed;

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final bubbleColor = isUser ? const Color(0xFF242426) : Colors.black;
    const textColor = Colors.white;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final widthFactor = isUser ? (embedded ? 0.90 : 0.78) : (embedded ? 0.96 : 0.86);
    final fixedCap = isUser ? (embedded ? 360.0 : 420.0) : (embedded ? 390.0 : 460.0);
    final maxBubbleWidth = math.min(viewportWidth * widthFactor, fixedCap);

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxBubbleWidth,
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
                    isUser ? message.text : _readableAssistantText(message.text),
                    style: const TextStyle(
                      color: textColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                      height: 1.34,
                    ),
                  ),
                ),
              ),
              if (!isUser && canShowActions && (message.result?.payload.recommendedService != null || message.result?.upgradePlan != null)) ...[
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
    required this.onServiceSelected,
    required this.onOneOffPurchaseSelected,
    required this.onUpgradeSelected,
    required this.onPlanUpgradeConfirmed,
  });

  final _AiChatTurnResult result;
  final bool sending;
  final void Function(String service, _AiChatTurnResult result) onServiceSelected;
  final void Function(String service, _AiChatTurnResult result) onOneOffPurchaseSelected;
  final void Function(_AiChatTurnResult result) onUpgradeSelected;
  final void Function(_ChatSubscriptionPlan plan, _AiChatTurnResult result) onPlanUpgradeConfirmed;

  @override
  Widget build(BuildContext context) {
    final payload = result.payload;
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
      final recommendedService = payload.recommendedService == 'scheduled_video' ? 'video' : payload.recommendedService;
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
              label: _productActionLabel(payload.actionLabel, recommendedService),
              selected: true,
              enabled: !sending,
              onTap: () => onServiceSelected(recommendedService, result),
            ),
          if (!result.noActiveSubscription)
            _ServiceButton(
              label: service == 'video' ? 'comprar video único' : 'comprar chat único',
              selected: true,
              enabled: !sending,
              onTap: () => onOneOffPurchaseSelected(service, result),
            ),
          _ServiceButton(
            label: 'mejorar plan',
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
          label: selected ? _productActionLabel(payload.actionLabel, service) : _serviceLabel(service),
          selected: selected,
          enabled: !sending,
          onTap: () => onServiceSelected(service, result),
        );
      }).toList(growable: false),
    );
  }

  String _serviceLabel(String service) {
    return switch (service) {
      'video' => 'video ahora',
      'scheduled_video' => 'agendar video',
      _ => 'chat',
    };
  }

  String _productActionLabel(String? label, String service) {
    final fallback = _serviceLabel(service);
    final normalized = (label ?? '').trim();
    if (normalized.isEmpty) return fallback;
    final lower = normalized.toLowerCase();
    if (lower.contains('responder') || lower.contains('pregunta') || lower.contains('triaje')) {
      return fallback;
    }
    final mentionsProduct = lower.contains('chat') || lower.contains('video') || lower.contains('videollamada') || lower.contains('agendar');
    final isAction = lower.contains('iniciar') || lower.contains('empezar') || lower.contains('continuar') || lower.contains('agendar');
    return mentionsProduct && isAction ? normalized : fallback;
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

class _ComposerFrameState extends State<_ComposerFrame> with SingleTickerProviderStateMixin {
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
        final pulse = widget.active ? 0.72 + (math.sin(phase * 0.82) + 1) * 0.12 : 1.0;
        final drift = widget.active ? math.sin(phase) * 7.5 + math.sin(phase * 2.15) * 2.0 : 0.0;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(28),
            boxShadow: widget.active
                ? [
                    BoxShadow(
                      color: const Color(0xFF57546F).withValues(alpha: (widget.thinking ? 0.12 : 0.075) * pulse),
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
  const _ComposerOutlinePainter({required this.progress, required this.thinking});

  final double progress;
  final bool thinking;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect.deflate(0.7), const Radius.circular(28));
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

enum _ChatRole { user, assistant }

class _ChatMessage {
  _ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    this.result,
    this.includeInHistory = true,
  });

  factory _ChatMessage.user(String text) {
    return _ChatMessage(id: _nextChatMessageId(), role: _ChatRole.user, text: text);
  }

  factory _ChatMessage.assistant(
    String text, {
    _AiChatTurnResult? result,
    bool includeInHistory = true,
  }) {
    return _ChatMessage(
      id: _nextChatMessageId(),
      role: _ChatRole.assistant,
      text: text,
      result: result,
      includeInHistory: includeInHistory,
    );
  }

  final String id;
  final _ChatRole role;
  final String text;
  final _AiChatTurnResult? result;
  final bool includeInHistory;

  bool get isUser => role == _ChatRole.user;
}

class _AiChatTurnResult {
  const _AiChatTurnResult({
    required this.payload,
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
    this.remaining,
  });

  factory _AiChatTurnResult.fromJson(Map<String, dynamic> json) {
    final payload = _AiChatPayload.fromJson(_asMap(json['payload']) ?? <String, dynamic>{});
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
        final firstVet = vets == null || vets.isEmpty ? null : _asMap(vets.first);
        vetId ??= _uuidFrom(firstVet?['id']);
        vetName = firstVet?['full_name']?.toString();
      }
      if (name == 'check_service_access') {
        serviceAccessType = output?['serviceType']?.toString();
        final canUseValue = output?['canUse'];
        serviceCanUse = canUseValue is bool ? canUseValue : null;
        serviceAccessReason = output?['reason']?.toString();
        final value = output?['remaining'];
        remaining = value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
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
  final int? remaining;

  String get commerceService {
    if (commerceServiceOverride == 'video' || commerceServiceOverride == 'chat') return commerceServiceOverride!;
    final recommended = payload.recommendedService == 'scheduled_video' ? 'video' : payload.recommendedService;
    final accessType = serviceAccessType == 'video' || serviceAccessType == 'chat' ? serviceAccessType : null;
    return accessType ?? (recommended == 'video' ? 'video' : 'chat');
  }

  bool get noActiveSubscription => serviceAccessReason == 'no_active_subscription';

  bool get canRetryActivationAfterUpgrade {
    return serviceCanUse == false &&
        (commerceService == 'chat' || commerceService == 'video') &&
        petId != null &&
        vetId != null &&
        specialtyId != null;
  }

  bool get entitlementExhaustedForRecommendedService {
    final exhausted = serviceCanUse == false || (serviceAccessType != null && remaining != null && remaining! <= 0);
    if (!exhausted) return false;
    if (commerceServiceOverride != null) return true;
    if (serviceCanUse == false && (serviceAccessType == 'chat' || serviceAccessType == 'video')) return true;
    final recommended = payload.recommendedService;
    if (recommended == null) return serviceAccessType == 'chat' || serviceAccessType == 'video';
    final target = recommended == 'scheduled_video' ? 'video' : recommended;
    final accessType = serviceAccessType == 'scheduled_video' ? 'video' : serviceAccessType;
    return accessType == null || accessType == target;
  }

  _AiChatTurnResult withEntitlement({
    required String serviceType,
    required bool canUse,
    required int remaining,
    String? reason,
  }) {
    return _AiChatTurnResult(
      payload: payload,
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
      remaining: remaining,
    );
  }

  _AiChatTurnResult withUpgradePlan(_ChatSubscriptionPlan plan) {
    return _AiChatTurnResult(
      payload: payload,
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
      remaining: remaining,
    );
  }
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

class _SubscriptionUpgradeOption {
  const _SubscriptionUpgradeOption({required this.currentPlan, required this.targetPlan, required this.usage});

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
    final included = service == 'video' ? plan.includedVideos : plan.includedChats;
    final consumed = service == 'video' ? consumedVideos : consumedChats;
    return math.max(included - consumed, 0);
  }

  int get remainingChats => math.max(includedChats - consumedChats, 0);
  int get remainingVideos => math.max(includedVideos - consumedVideos, 0);

  String get aiSummary => '$consumedChats de $includedChats chats consumidos y $consumedVideos de $includedVideos videollamadas consumidas';
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
        ? included.map((item) => item.toString()).where((item) => item.trim().isNotEmpty).toList()
        : const <String>[];
    return _ChatSubscriptionPlan(
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      monthlyCents: _toInt(json['price_monthly_cents']) ?? _toInt(json['price_cents']) ?? 0,
      currency: (json['currency']?.toString() ?? 'MXN').toUpperCase(),
      includedChats: _toInt(json['included_chats']) ?? 0,
      includedVideos: _toInt(json['included_videos']) ?? 0,
      petsIncludedDefault: _toInt(json['pets_included_default']) ?? 1,
      descriptionMain: (marketing['main']?.toString() ?? json['description']?.toString() ?? '').trim(),
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
    final amount = monthlyCents % 100 == 0 ? (monthlyCents ~/ 100).toString() : (monthlyCents / 100).toStringAsFixed(2);
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
      if (descriptionIncluded.isNotEmpty) 'Incluye: ${descriptionIncluded.take(3).join('; ')}',
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

_ChatSubscriptionPlan? _findPlanByCode(List<_ChatSubscriptionPlan> plans, String code) {
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
    RegExp(r'(:)\s+(\d+\.\s)'),
    (match) => '${match[1]}\n\n${match[2]}',
  );
  formatted = formatted.replaceAllMapped(
    RegExp(r'([^\n])\n(\d+\.\s)'),
    (match) => '${match[1]}\n\n${match[2]}',
  );
  formatted = formatted.replaceAllMapped(
    RegExp(r'([.!?])\s+(?=(Te recomiendo|Para |Si ves|Si empeora|Mientras|Respóndeme|¿))'),
    (match) => '${match[1]}\n\n',
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
