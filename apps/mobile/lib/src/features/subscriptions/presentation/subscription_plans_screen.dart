import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:cav_mobile/src/core/config/environment.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

const bool _subscriptionFlowDebug = bool.fromEnvironment(
  'SUBSCRIPTION_FLOW_DEBUG',
  defaultValue: true,
);

void _subscriptionLog(String message) {
  if (_subscriptionFlowDebug) {
    debugPrint('[Subscriptions][Flow] $message');
  }
}

class SubscriptionPlansLoaderScreen extends StatefulWidget {
  const SubscriptionPlansLoaderScreen({
    super.key,
    this.horsesTarget,
  });

  final int? horsesTarget;

  @override
  State<SubscriptionPlansLoaderScreen> createState() =>
      _SubscriptionPlansLoaderScreenState();
}

class _SubscriptionPlansLoaderScreenState
    extends State<SubscriptionPlansLoaderScreen> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
    );
    unawaited(_prepareAndContinue());
  }

  Future<void> _prepareAndContinue() async {
    final startedAt = DateTime.now();
    final userId = Supabase.instance.client.auth.currentUser?.id;
    _subscriptionLog('Loader started. userId=$userId horsesTarget=${widget.horsesTarget}');

    final active =
        await _SubscriptionPlansRepository.instance.fetchActiveSubscription();
    _subscriptionLog(
      'Active subscription check completed. found=${active.hasActive} '
      'status=${active.status} plan=${active.planCode} subId=${active.subscriptionId}',
    );

    final elapsed = DateTime.now().difference(startedAt);
    const minDuration = Duration(milliseconds: 1200);
    if (elapsed < minDuration) {
      await Future.delayed(minDuration - elapsed);
    }
    if (!mounted) return;

    if (active.hasActive) {
      _subscriptionLog(
          'User already has active subscription. Routing to /home');
      context.go('/home');
      return;
    }

    final recommendation =
        await _SubscriptionPlansRepository.instance.prepareSuggestions(
      horsesTarget: widget.horsesTarget,
    );
    _subscriptionLog('Suggestions prepared. recommended=$recommendation');

    if (!mounted) return;
    final query = recommendation == null ? '' : '?recommended=$recommendation';
    _subscriptionLog('Routing to /subscription-plans$query');
    context.go('/subscription-plans$query');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              image: DecorationImage(
                image: AssetImage('assets/images/onboarding/rectangle_1.png'),
                fit: BoxFit.cover,
              ),
            ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: Container(
                color: Colors.black.withValues(alpha: 0.08),
              ),
            ),
          ),
          Align(
            alignment: const Alignment(0, 0.45),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text(
                  'call a vet',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontFamily: 'ABC Diatype',
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: 18),
                SizedBox(
                  width: 312,
                  child: Text(
                    'estamos casi listos...',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontFamily: 'ABC Diatype',
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Positioned(
            right: 24,
            bottom: 86,
            child: _ContinueCta(
              label: 'conoce nuestros planes',
              enabled: false,
            ),
          ),
        ],
      ),
    );
  }
}

class SubscriptionPlansScreen extends StatefulWidget {
  const SubscriptionPlansScreen({
    super.key,
    this.recommendedCode,
  });

  final String? recommendedCode;

  @override
  State<SubscriptionPlansScreen> createState() =>
      _SubscriptionPlansScreenState();
}

class _SubscriptionPlansScreenState extends State<SubscriptionPlansScreen> {
  bool _isLoading = true;
  bool _isSubscribing = false;
  String? _error;
  bool _isAnnual = false;
  List<_SubscriptionPlan> _plans = const [];
  _SubscriptionPlan? _selectedPlan;
  String? _recommendedCode;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
    );
    unawaited(_load());
  }

  Future<void> _load() async {
    _subscriptionLog(
      'Plans screen load started. recommendedCode=${widget.recommendedCode}',
    );
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final plans = await _SubscriptionPlansRepository.instance.fetchPlans();
      if (plans.isEmpty) {
        _subscriptionLog('Plans fetch completed with empty list.');
        setState(() {
          _plans = const [];
          _selectedPlan = null;
          _recommendedCode = null;
          _error = 'No hay planes disponibles por ahora.';
          _isLoading = false;
        });
        return;
      }

      final planByCode = <String, _SubscriptionPlan>{
        for (final plan in plans) plan.code.toLowerCase(): plan,
      };
      final suggestedCode = widget.recommendedCode?.trim().toLowerCase();
      String? resolvedRecommendedCode =
          (suggestedCode != null && planByCode.containsKey(suggestedCode))
              ? suggestedCode
              : _SubscriptionPlansRepository.instance.cachedRecommendedCode;

      if (resolvedRecommendedCode == null) {
        resolvedRecommendedCode =
            await _SubscriptionPlansRepository.instance.prepareSuggestions();
      }

      setState(() {
        _plans = plans;
        _recommendedCode = resolvedRecommendedCode;
        _selectedPlan = resolvedRecommendedCode == null
            ? plans.first
            : planByCode[resolvedRecommendedCode] ?? plans.first;
        _isLoading = false;
      });

      _subscriptionLog(
        'Plans fetched. count=${plans.length} recommended=$resolvedRecommendedCode '
        'initialSelected=${_selectedPlan?.code}',
      );
    } catch (err) {
      _subscriptionLog('Plans load failed: $err');
      setState(() {
        _error = 'No se pudieron cargar los planes.';
        _isLoading = false;
      });
    }
  }

  void _handlePlanSelected(_SubscriptionPlan plan) {
    _subscriptionLog(
      'Plan selected. code=${plan.code} name=${plan.displayName} '
      'monthly=${plan.monthlyCents} annual=${plan.annualCents}',
    );
    setState(() => _selectedPlan = plan);
  }

  Future<void> _handleSubscribe(_SubscriptionPlan selected) async {
    if (_isSubscribing) return;
    _subscriptionLog(
      'Subscribe tapped. selected=${selected.code} '
      'display=${selected.displayName} annual=$_isAnnual',
    );

    setState(() => _isSubscribing = true);
    try {
      final active =
          await _SubscriptionPlansRepository.instance.fetchActiveSubscription();
      _subscriptionLog(
        'Pre-subscribe active check. found=${active.hasActive} '
        'status=${active.status} plan=${active.planCode}',
      );

      if (active.hasActive) {
        _subscriptionLog(
          'Attempting DB patch via /subscriptions/change-plan '
          'from=${active.planCode} to=${selected.code}',
        );
        final changeResult = await _SubscriptionPlansRepository.instance
            .changePlan(selected.code);
        _subscriptionLog('change-plan response: $changeResult');

        if (!mounted) return;
        if (changeResult['ok'] == true) {
          _subscriptionLog('Subscription patch succeeded. Routing to /subscription-success');
          context.go('/subscription-success?plan=${selected.code}');
          return;
        }

        final reason = changeResult['reason']?.toString() ?? 'unknown_error';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo actualizar el plan: $reason')),
        );
        return;
      }

      _subscriptionLog(
        'No active subscription. Activating subscription server-side for plan=${selected.code}',
      );
      final activationResult =
          await _SubscriptionPlansRepository.instance.activatePlan(selected.code);
      _subscriptionLog('activate-plan response: $activationResult');

      if (!mounted) return;
      if (activationResult['ok'] == true) {
        context.go('/subscription-success?plan=${selected.code}');
        return;
      }

      final reason = activationResult['reason']?.toString() ?? 'unknown_error';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo activar la suscripción: $reason')),
      );
    } catch (err) {
      _subscriptionLog('Subscribe flow failed: $err');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error al procesar la suscripción.')),
      );
    } finally {
      if (mounted) {
        setState(() => _isSubscribing = false);
      }
      _subscriptionLog('Subscribe flow finished.');
    }
  }

  String _formatPrice(int cents) {
    final pesos = (cents / 100).round();
    return '\$$pesos';
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedPlan;
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              image: DecorationImage(
                image: AssetImage('assets/images/onboarding/rectangle_1.png'),
                fit: BoxFit.cover,
              ),
            ),
          ),
          DecoratedBox(
            decoration:
                BoxDecoration(color: Colors.black.withValues(alpha: 0.14)),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(0.50, -0.00),
                end: Alignment(0.50, 1.00),
                colors: [Color.fromRGBO(0, 0, 0, 0), Colors.black],
              ),
            ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: Container(
                color: Colors.black.withValues(alpha: 0.10),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => context.go('/home'),
                      style:
                          TextButton.styleFrom(foregroundColor: Colors.white),
                      child: const Text(
                        'saltar',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontFamily: 'ABC Diatype',
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(
                    width: 351,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: 'nuestros planes: ',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontFamily: 'ABC Diatype',
                              fontWeight: FontWeight.w500,
                              height: 1.10,
                            ),
                          ),
                          TextSpan(
                            text:
                                'desde un solo caballo hasta operaciones completas.',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontFamily: 'ABC Diatype',
                              fontWeight: FontWeight.w300,
                              height: 1.10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'selecciona uno para conocer los detalles',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontFamily: 'ABC Diatype',
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_isLoading)
                    const Expanded(
                      child: Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                    )
                  else if (_error != null)
                    Expanded(
                      child: Center(
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontFamily: 'ABC Diatype',
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                    )
                  else ...[
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: _plans
                          .map(
                            (plan) => _PlanChip(
                              label: plan.displayName,
                              selected: _selectedPlan?.id == plan.id,
                              isRecommended:
                                  _recommendedCode == plan.code.toLowerCase(),
                              onTap: () => _handlePlanSelected(plan),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 20),
                    Align(
                      alignment: Alignment.centerRight,
                      child: GestureDetector(
                        onTap: () => setState(() => _isAnnual = !_isAnnual),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: 'mensual',
                                style: TextStyle(
                                  color: _isAnnual
                                      ? Colors.white.withValues(alpha: 0.30)
                                      : Colors.white,
                                  fontSize: 12,
                                  fontFamily: 'ABC Diatype',
                                  fontWeight: FontWeight.w400,
                                  decoration: _isAnnual
                                      ? TextDecoration.none
                                      : TextDecoration.underline,
                                ),
                              ),
                              const TextSpan(
                                text: '  |  ',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontFamily: 'ABC Diatype',
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                              TextSpan(
                                text: 'anual',
                                style: TextStyle(
                                  color: _isAnnual
                                      ? Colors.white
                                      : Colors.white.withValues(alpha: 0.14),
                                  fontSize: 12,
                                  fontFamily: 'ABC Diatype',
                                  fontWeight: FontWeight.w400,
                                  decoration: _isAnnual
                                      ? TextDecoration.underline
                                      : TextDecoration.none,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: SingleChildScrollView(
                        child: _PlanDescription(
                          plan: selected,
                          isAnnual: _isAnnual,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      SizedBox(
                        height: 38,
                        child: ElevatedButton(
                          onPressed: (selected == null || _isSubscribing)
                              ? null
                              : () => _handleSubscribe(selected),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(33.50),
                            ),
                          ),
                          child: _isSubscribing
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.black,
                                    ),
                                  ),
                                )
                              : const Text(
                                  'contratar',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.black,
                                    fontSize: 12,
                                    fontFamily: 'ABC Diatype',
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                        ),
                      ),
                      const Spacer(),
                      _ContinueCta(
                        label: 'continuar',
                        onTap: () => context.go('/home'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanDescription extends StatelessWidget {
  const _PlanDescription({
    required this.plan,
    required this.isAnnual,
  });

  final _SubscriptionPlan? plan;
  final bool isAnnual;

  @override
  Widget build(BuildContext context) {
    if (plan == null) {
      return const SizedBox.shrink();
    }

    final includedItems = plan!.descriptionIncluded;
    final priceText =
        _formatPrice(isAnnual ? plan!.annualCents : plan!.monthlyCents);
    final periodText = isAnnual ? 'al año' : 'al mes';

    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '${plan!.displayName} - $priceText $periodText\n',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w500,
              height: 0.90,
            ),
          ),
          TextSpan(
            text: '\n${plan!.descriptionMain}\n\n',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w300,
              height: 1.38,
            ),
          ),
          const TextSpan(
            text: 'Incluye:\n\n',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w500,
              height: 1.38,
            ),
          ),
          TextSpan(
            text: includedItems.isEmpty
                ? _fallbackIncluded(plan!)
                : includedItems.map((item) => '$item\n').join(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w300,
              height: 1.38,
            ),
          ),
          const TextSpan(
            text: '\nPor qué conviene:\n\n',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w500,
              height: 1.38,
            ),
          ),
          TextSpan(
            text: '${plan!.descriptionValue}\n\n',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w300,
              height: 1.38,
            ),
          ),
          const TextSpan(
            text: 'Resultado:\n\n',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w500,
              height: 1.38,
            ),
          ),
          TextSpan(
            text: _resolvedResultText(plan!),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w300,
              height: 1.38,
            ),
          ),
        ],
      ),
    );
  }

  String _fallbackIncluded(_SubscriptionPlan plan) {
    return '${plan.includedVideos} videollamadas veterinarias al mes.\n'
        '${plan.includedChats} chats veterinarios al mes.\n'
        'Cobertura para ${plan.petsIncludedDefault} caballo(s).';
  }

  String _resolvedResultText(_SubscriptionPlan plan) {
    final text = plan.descriptionResult.trim();
    if (text.isNotEmpty) return text;
    return 'Mayor previsibilidad de costos y atención veterinaria más rápida para tus caballos.';
  }

  String _formatPrice(int cents) {
    final pesos = (cents / 100).round();
    return '\$$pesos';
  }

}

class _PlanChip extends StatelessWidget {
  const _PlanChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.isRecommended,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool isRecommended;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isRecommended)
          Container(
            margin: const EdgeInsets.only(left: 14, bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: ShapeDecoration(
              color: const Color(0xFF101010),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(40),
              ),
            ),
            child: const Text(
              'recomendado',
              style: TextStyle(
                color: Colors.white,
                fontSize: 8,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: ShapeDecoration(
              color: selected ? Colors.white : Colors.white.withValues(alpha: 0.06),
              shape: RoundedRectangleBorder(
                side: selected && isRecommended
                    ? const BorderSide(width: 1, color: Colors.white)
                    : BorderSide.none,
                borderRadius: BorderRadius.circular(40),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? Colors.black : Colors.white,
                    fontSize: 13,
                    fontFamily: 'ABC Diatype',
                    fontWeight: FontWeight.w500,
                    height: 1.40,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ContinueCta extends StatelessWidget {
  const _ContinueCta({
    required this.label,
    this.onTap,
    this.enabled = true,
  });

  final String label;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.7,
        child: Row(
          mainAxisSize: MainAxisSize.min,
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
            const SizedBox(width: 10),
            Container(
              width: 45,
              height: 45,
              decoration: const ShapeDecoration(
                color: Colors.white,
                shape: OvalBorder(),
              ),
              child: const Icon(
                Icons.arrow_forward,
                color: Colors.black,
                size: 20,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionPlansRepository {
  _SubscriptionPlansRepository._();

  static final instance = _SubscriptionPlansRepository._();

  List<_SubscriptionPlan>? _cachedPlans;
  String? cachedRecommendedCode;

  Future<_ActiveSubscriptionCheck> fetchActiveSubscription() async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    _subscriptionLog('Checking active subscriptions. userId=$userId');

    if (token == null || token.isEmpty) {
      _subscriptionLog(
          'Active subscription check aborted: missing auth token.');
      return const _ActiveSubscriptionCheck();
    }

    final response = await _request(
      method: 'GET',
      path: '/subscriptions/my',
      token: token,
    );
    final data = response is Map<String, dynamic> ? response['data'] : null;
    if (data is! List) {
      _subscriptionLog(
          'Active subscription check got non-list data: $response');
      return const _ActiveSubscriptionCheck();
    }

    final rows = data.whereType<Map>().map((row) {
      final map = Map<String, dynamic>.from(row);
      final plan = map['plan'];
      final planCode = plan is Map ? plan['code']?.toString() : null;
      return _ActiveSubscriptionCheck(
        hasActive: false,
        subscriptionId: map['id']?.toString(),
        status: map['status']?.toString(),
        planCode: planCode,
      );
    }).toList();

    final active = rows.firstWhere(
      (row) =>
          (row.status ?? '').toLowerCase() == 'active' ||
          (row.status ?? '').toLowerCase() == 'trialing',
      orElse: () => const _ActiveSubscriptionCheck(),
    );

    _subscriptionLog(
      'Active subscription check result. total=${rows.length} '
      'hasActive=${active.status != null} status=${active.status} plan=${active.planCode}',
    );

    if (active.status != null) {
      return _ActiveSubscriptionCheck(
        hasActive: true,
        subscriptionId: active.subscriptionId,
        status: active.status,
        planCode: active.planCode,
      );
    }

    return const _ActiveSubscriptionCheck();
  }

  Future<String?> prepareSuggestions({int? horsesTarget}) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    _subscriptionLog(
      'Preparing suggestions via gateway. horsesTarget=$horsesTarget tokenAvailable=${token != null && token.isNotEmpty}',
    );

    if (token != null && token.isNotEmpty) {
      try {
        final query =
            (horsesTarget != null && horsesTarget > 0) ? '?horses=$horsesTarget' : '';
        final recommendationResponse = await _request(
          method: 'GET',
          path: '/subscriptions/recommendation$query',
          token: token,
        );

        if (recommendationResponse is Map<String, dynamic>) {
          final recommendedCode =
              recommendationResponse['recommendedCode']?.toString().trim().toLowerCase();
          if (recommendedCode != null && recommendedCode.isNotEmpty) {
            cachedRecommendedCode = recommendedCode;
            _subscriptionLog(
              'Gateway recommendation resolved. recommendedCode=$cachedRecommendedCode '
              'strategy=${recommendationResponse['strategy']} horsesTarget=${recommendationResponse['horsesTarget']}',
            );
            return cachedRecommendedCode;
          }
          _subscriptionLog(
            'Gateway recommendation returned no code. response=$recommendationResponse',
          );
        }
      } catch (err) {
        _subscriptionLog('Gateway recommendation request failed: $err');
      }
    }

    final plans = await fetchPlans();
    if (plans.isEmpty) {
      cachedRecommendedCode = null;
      _subscriptionLog('No plans available while preparing suggestions.');
      return null;
    }

    cachedRecommendedCode = plans.first.code.toLowerCase();
    _subscriptionLog(
      'Fallback recommendation resolved to first active plan. '
      'recommendedCode=$cachedRecommendedCode',
    );
    return cachedRecommendedCode;
  }

  Future<List<_SubscriptionPlan>> fetchPlans() async {
    if (_cachedPlans != null) return _cachedPlans!;

    final uri = Uri.parse('${Environment.apiBaseUrl}/plans');
    final http = HttpClient();
    try {
      final req = await http.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');

      _subscriptionLog('Fetching plans from /plans');
      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();
      _subscriptionLog('Plans response status=${res.statusCode} body=$body');

      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException('plans_fetch_failed_${res.statusCode}');
      }

      final decoded = jsonDecode(body);
      final items = (decoded is Map<String, dynamic> ? decoded['items'] : null);
      if (items is! List) {
        _cachedPlans = const [];
        return _cachedPlans!;
      }

      final plans = items
          .whereType<Map>()
          .map((raw) =>
              _SubscriptionPlan.fromJson(Map<String, dynamic>.from(raw)))
          .toList();

      plans.sort((a, b) {
        final indexA = _planOrder.indexOf(a.code.toLowerCase());
        final indexB = _planOrder.indexOf(b.code.toLowerCase());
        if (indexA == -1 && indexB == -1) {
          return a.monthlyCents.compareTo(b.monthlyCents);
        }
        if (indexA == -1) return 1;
        if (indexB == -1) return -1;
        return indexA.compareTo(indexB);
      });

      _cachedPlans = plans;
      return plans;
    } finally {
      http.close(force: true);
    }
  }

  Future<bool> hasActiveSubscription() async {
    final result = await fetchActiveSubscription();
    return result.hasActive;
  }

  Future<Map<String, dynamic>> changePlan(String code) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      _subscriptionLog('changePlan aborted: missing auth token. code=$code');
      return {'ok': false, 'reason': 'missing_auth_token'};
    }

    _subscriptionLog('Calling /subscriptions/change-plan with code=$code');
    final response = await _request(
      method: 'POST',
      path: '/subscriptions/change-plan',
      token: token,
      body: {'code': code},
    );

    if (response is Map<String, dynamic>) {
      return response;
    }
    return {'ok': false, 'reason': 'invalid_change_plan_response'};
  }

  Future<String?> createStripeCheckout(String code) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      _subscriptionLog(
        'createStripeCheckout aborted: missing auth token. code=$code',
      );
      return null;
    }

    _subscriptionLog(
        'Calling /subscriptions/stripe/checkout with plan_code=$code');
    final response = await _request(
      method: 'POST',
      path: '/subscriptions/stripe/checkout',
      token: token,
      body: {'plan_code': code},
    );

    if (response is! Map<String, dynamic>) return null;
    return response['url']?.toString();
  }

  Future<Map<String, dynamic>> activatePlan(String code) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      _subscriptionLog('activatePlan aborted: missing auth token. code=$code');
      return {'ok': false, 'reason': 'missing_auth_token'};
    }

    _subscriptionLog('Calling /subscriptions/activate-plan with code=$code');
    final response = await _request(
      method: 'POST',
      path: '/subscriptions/activate-plan',
      token: token,
      body: {'code': code},
    );

    if (response is Map<String, dynamic>) {
      return response;
    }
    return {'ok': false, 'reason': 'invalid_activate_plan_response'};
  }

  Future<dynamic> _request({
    required String method,
    required String path,
    required String token,
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('${Environment.apiBaseUrl}$path');
    final http = HttpClient();
    try {
      final req = switch (method) {
        'POST' => await http.postUrl(uri),
        _ => await http.getUrl(uri),
      };
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.add(utf8.encode(jsonEncode(body)));
      }

      _subscriptionLog(
          'HTTP request started. method=$method path=$path body=$body');
      final res = await req.close();
      final raw = await utf8.decoder.bind(res).join();
      _subscriptionLog(
        'HTTP response received. method=$method path=$path '
        'status=${res.statusCode} body=$raw',
      );

      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException('gateway_request_failed_${res.statusCode}');
      }
      if (raw.isEmpty) return null;
      return jsonDecode(raw);
    } finally {
      http.close(force: true);
    }
  }

}

const List<String> _planOrder = [
  'starter',
  'plus',
  'cuadra',
  'cuadra-15',
  'pro-entrenador',
  'rancho-trabajo',
];

class _ActiveSubscriptionCheck {
  const _ActiveSubscriptionCheck({
    this.hasActive = false,
    this.subscriptionId,
    this.status,
    this.planCode,
  });

  final bool hasActive;
  final String? subscriptionId;
  final String? status;
  final String? planCode;
}

class _SubscriptionPlan {
  const _SubscriptionPlan({
    required this.id,
    required this.code,
    required this.name,
    required this.monthlyCents,
    required this.annualCents,
    required this.includedChats,
    required this.includedVideos,
    required this.petsIncludedDefault,
    required this.descriptionMain,
    required this.descriptionIncluded,
    required this.descriptionValue,
    required this.descriptionResult,
  });

  final String id;
  final String code;
  final String name;
  final int monthlyCents;
  final int annualCents;
  final int includedChats;
  final int includedVideos;
  final int petsIncludedDefault;
  final String descriptionMain;
  final List<String> descriptionIncluded;
  final String descriptionValue;
  final String descriptionResult;

  String get displayName {
    final key = code.toLowerCase();
    return switch (key) {
      'starter' => 'starter',
      'plus' => 'plus',
      'cuadra' => 'cuadra 5',
      'cuadra-15' => 'cuadra 15',
      'pro-entrenador' => 'entrenador',
      'rancho-trabajo' => 'rancho de trabajo',
      _ => name.toLowerCase(),
    };
  }

  factory _SubscriptionPlan.fromJson(Map<String, dynamic> json) {
    final rawMarketing = json['description_json'];
    Map<String, dynamic> marketing = const {};
    if (rawMarketing is Map<String, dynamic>) {
      marketing = rawMarketing;
    } else if (rawMarketing is String && rawMarketing.trim().isNotEmpty) {
      final decoded = jsonDecode(rawMarketing);
      if (decoded is Map<String, dynamic>) {
        marketing = decoded;
      }
    }

    final included = marketing['included'];
    final includedList = included is List
        ? included
            .map((item) => item.toString())
            .where((item) => item.trim().isNotEmpty)
            .toList()
        : const <String>[];

    final monthly =
        _toInt(json['price_monthly_cents']) ?? _toInt(json['price_cents']) ?? 0;
    final annual = _toInt(json['price_annual_cents']) ?? monthly;

    return _SubscriptionPlan(
      id: json['id']?.toString() ?? '',
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      monthlyCents: monthly,
      annualCents: annual,
      includedChats: _toInt(json['included_chats']) ?? 0,
      includedVideos: _toInt(json['included_videos']) ?? 0,
      petsIncludedDefault: _toInt(json['pets_included_default']) ?? 1,
      descriptionMain: (marketing['main']?.toString() ??
              json['description']?.toString() ??
              '')
          .trim(),
      descriptionIncluded: includedList,
      descriptionValue: (marketing['value']?.toString() ?? '').trim(),
      descriptionResult: (marketing['result']?.toString() ?? '').trim(),
    );
  }

  static int? _toInt(Object? value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }
}

class SubscriptionSuccessMockScreen extends StatelessWidget {
  const SubscriptionSuccessMockScreen({
    super.key,
    this.planCode,
  });

  final String? planCode;

  @override
  Widget build(BuildContext context) {
    final planLabel = (planCode ?? '').trim().isEmpty
        ? 'tu plan'
        : (planCode ?? '').replaceAll('-', ' ');

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              image: DecorationImage(
                image: AssetImage('assets/images/onboarding/rectangle_1.png'),
                fit: BoxFit.cover,
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55)),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Spacer(),
                  const Icon(
                    Icons.check_circle_rounded,
                    color: Colors.white,
                    size: 74,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'suscripción activada',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontFamily: 'ABC Diatype',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Tu plan $planLabel ya está activo.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontFamily: 'ABC Diatype',
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: () => context.go('/home'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(33.5),
                        ),
                      ),
                      child: const Text(
                        'ir al inicio',
                        style: TextStyle(
                          fontSize: 14,
                          fontFamily: 'ABC Diatype',
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
