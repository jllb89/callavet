import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:country_picker/country_picker.dart';
import 'package:country_picker/src/country_list_view.dart';
import 'package:cav_mobile/src/core/config/environment.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_libphonenumber/flutter_libphonenumber.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const int _otpMaxAttemptsPerWindow = 3;
const Duration _otpAttemptWindow = Duration(minutes: 15);
const bool _bypassOtpValidationForDev = bool.fromEnvironment(
  'BYPASS_OTP',
  defaultValue: false,
);
const bool _kycLocationDebug = bool.fromEnvironment(
  'KYC_LOCATION_DEBUG',
  defaultValue: true,
);
const bool _kycFlowDebug = bool.fromEnvironment(
  'KYC_FLOW_DEBUG',
  defaultValue: true,
);

const List<String> _mexicanStates = [
  'Aguascalientes',
  'Baja California',
  'Baja California Sur',
  'Campeche',
  'Chiapas',
  'Chihuahua',
  'Ciudad de México',
  'Coahuila',
  'Colima',
  'Durango',
  'Estado de México',
  'Guanajuato',
  'Guerrero',
  'Hidalgo',
  'Jalisco',
  'Michoacán',
  'Morelos',
  'Nayarit',
  'Nuevo León',
  'Oaxaca',
  'Puebla',
  'Querétaro',
  'Quintana Roo',
  'San Luis Potosí',
  'Sinaloa',
  'Sonora',
  'Tabasco',
  'Tamaulipas',
  'Tlaxcala',
  'Veracruz',
  'Yucatán',
  'Zacatecas',
];

const Map<String, String> _mexicanStateAliases = {
  'cdmx': 'Ciudad de México',
  'ciudad de mexico': 'Ciudad de México',
  'distrito federal': 'Ciudad de México',
  'estado de mexico': 'Estado de México',
  'edomex': 'Estado de México',
  'nuevo leon': 'Nuevo León',
  'san luis potosi': 'San Luis Potosí',
  'michoacan': 'Michoacán',
  'queretaro': 'Querétaro',
  'yucatan': 'Yucatán',
};

void _kycLog(String message) {
  if (_kycLocationDebug) {
    debugPrint('[KYC][Location] $message');
  }
}

void _kycFlowLog(String message) {
  if (_kycFlowDebug) {
    debugPrint('[KYC][Flow] $message');
  }
}

String _normalizeLocationText(String input) {
  final base = input
      .trim()
      .toLowerCase()
      .replaceAll('á', 'a')
      .replaceAll('é', 'e')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll('ú', 'u')
      .replaceAll('ü', 'u')
      .replaceAll('ñ', 'n');
  return base.replaceAll(RegExp(r'\s+'), ' ');
}

String? _matchMexicanState(String raw) {
  final normalizedRaw = _normalizeLocationText(raw);
  if (normalizedRaw.isEmpty || normalizedRaw.length < 3) return null;

  final aliased = _mexicanStateAliases[normalizedRaw];
  if (aliased != null) return aliased;

  for (final state in _mexicanStates) {
    final normalizedState = _normalizeLocationText(state);
    if (normalizedRaw == normalizedState) {
      return state;
    }
    if (normalizedRaw.startsWith('$normalizedState ') ||
        normalizedRaw.endsWith(' $normalizedState') ||
        normalizedRaw.contains(' $normalizedState ')) {
      return state;
    }
    if (normalizedRaw.contains('estado de $normalizedState') ||
        normalizedRaw.contains('state of $normalizedState')) {
      return state;
    }
  }
  return null;
}

String _normalizePhoneForOtp(String input) {
  final compact = input.replaceAll(RegExp(r'[^0-9+]'), '');
  if (compact.startsWith('+')) return compact;
  final digits = compact.replaceAll(RegExp(r'[^0-9]'), '');
  return '+$digits';
}

class _OtpAttemptGuard {
  static final Map<String, List<DateTime>> _attemptsByPhone = {};

  static void _prune(String phone, DateTime now) {
    final attempts = _attemptsByPhone[phone];
    if (attempts == null) return;
    attempts.removeWhere((attempt) => now.difference(attempt) >= _otpAttemptWindow);
    if (attempts.isEmpty) {
      _attemptsByPhone.remove(phone);
    }
  }

  static Duration? retryAfter(String phone) {
    final now = DateTime.now();
    _prune(phone, now);
    final attempts = _attemptsByPhone[phone];
    if (attempts == null || attempts.length < _otpMaxAttemptsPerWindow) {
      return null;
    }
    final oldest = attempts.first;
    final elapsed = now.difference(oldest);
    if (elapsed >= _otpAttemptWindow) return null;
    return _otpAttemptWindow - elapsed;
  }

  static void register(String phone) {
    final now = DateTime.now();
    _prune(phone, now);
    final attempts = _attemptsByPhone.putIfAbsent(phone, () => <DateTime>[]);
    attempts.add(now);
  }
}

class KycScreen extends StatefulWidget {
  const KycScreen({
    super.key,
    this.startAtProfile = false,
  });

  final bool startAtProfile;

  @override
  State<KycScreen> createState() => _KycScreenState();
}

class _KycScreenState extends State<KycScreen> {
  final _pageController = PageController();
  final _phoneController = TextEditingController();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _stateController = TextEditingController();
  int _pageIndex = 0;
  String? _e164Phone;
  bool _isSendingOtp = false;
  bool _isSavingProfile = false;
  DateTime? _otpCooldownUntil;
  bool _showIsland = false;
  String _islandText = '';
  double _islandOpacity = 0;

  int get _profilePageIndex => _bypassOtpValidationForDev ? 1 : 2;

  @override
  void initState() {
    super.initState();
    final currentUser = Supabase.instance.client.auth.currentUser;
    _emailController.text = currentUser?.email ?? '';
    final fullName = currentUser?.userMetadata?['full_name'];
    if (fullName is String && fullName.trim().isNotEmpty) {
      _nameController.text = fullName.trim();
    }
    unawaited(_prefillProfileFromPublicUser());
    if (widget.startAtProfile) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _pageController.jumpToPage(_profilePageIndex);
        setState(() => _pageIndex = _profilePageIndex);
      });
    }
  }

  Future<void> _prefillProfileFromPublicUser() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    try {
      final row = await Supabase.instance.client
          .from('users')
          .select('full_name,email,state,country')
          .eq('id', user.id)
          .maybeSingle();
      if (row == null || !mounted) return;

      final fullName = (row['full_name'] as String?)?.trim();
      final email = (row['email'] as String?)?.trim();
      final state = (row['state'] as String?)?.trim();

      setState(() {
        if ((fullName ?? '').isNotEmpty && _nameController.text.trim().isEmpty) {
          _nameController.text = fullName!;
        }
        if ((email ?? '').isNotEmpty && _emailController.text.trim().isEmpty) {
          _emailController.text = email!;
        }
        if ((state ?? '').isNotEmpty && _stateController.text.trim().isEmpty) {
          _stateController.text = state!;
        }
      });
    } catch (err) {
      _kycFlowLog('Profile prefill lookup failed: $err');
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _phoneController.dispose();
    _nameController.dispose();
    _emailController.dispose();
    _stateController.dispose();
    super.dispose();
  }

  void _goNext() {
    final nextPage = _pageIndex + 1;
    final totalSteps = _bypassOtpValidationForDev ? 4 : 5;
    _kycFlowLog('Navigating next: current=$_pageIndex next=$nextPage totalSteps=$totalSteps bypassOtp=$_bypassOtpValidationForDev');
    if (nextPage < totalSteps) {
      _pageController.animateToPage(
        nextPage,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      context.go('/home');
    }
  }

  void _goBack() {
    if (_pageIndex == 0) return;
    _pageController.animateToPage(
      _pageIndex - 1,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _handlePhoneContinue(String e164Phone) async {
    if (_isSendingOtp) return;
    final normalizedPhone = _normalizePhoneForOtp(e164Phone);
    _kycFlowLog('Phone continue pressed. raw="$e164Phone" normalized="$normalizedPhone"');
    if (_bypassOtpValidationForDev) {
      _kycFlowLog('BYPASS_OTP=true, skipping OTP step and moving forward without auth verification');
      setState(() => _e164Phone = normalizedPhone);
      _goNext();
      return;
    }
    final guardRetryAfter = _OtpAttemptGuard.retryAfter(normalizedPhone);
    if (guardRetryAfter != null) {
      final minutes = guardRetryAfter.inMinutes;
      final seconds = guardRetryAfter.inSeconds % 60;
      final waitText = minutes > 0 ? '${minutes}m ${seconds}s' : '${seconds}s';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Límite temporal alcanzado. Intenta de nuevo en $waitText.')),
      );
      return;
    }
    final now = DateTime.now();
    if (_otpCooldownUntil != null && now.isBefore(_otpCooldownUntil!)) {
      final secondsLeft = _otpCooldownUntil!.difference(now).inSeconds + 1;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Espera $secondsLeft segundos antes de pedir otro código.')),
      );
      return;
    }
    setState(() {
      _isSendingOtp = true;
      _e164Phone = normalizedPhone;
    });
    try {
      final client = Supabase.instance.client;
      _kycFlowLog('Requesting OTP via signInWithOtp(phone=$normalizedPhone, channel=sms)');
      await client.auth.signInWithOtp(
        phone: normalizedPhone,
        shouldCreateUser: true,
        channel: OtpChannel.sms,
      );
      _kycFlowLog('OTP request accepted by Supabase for $normalizedPhone');
      _OtpAttemptGuard.register(normalizedPhone);
      _otpCooldownUntil = DateTime.now().add(const Duration(seconds: 60));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Código enviado a $normalizedPhone')),
        );
      }
      _goNext();
    } on AuthException catch (err) {
      _kycFlowLog('OTP request AuthException: ${err.message}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo enviar el código: ${err.message}')),
      );
    } catch (err) {
      _kycFlowLog('OTP request error: $err');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo enviar el código: $err')),
      );
    } finally {
      if (mounted) {
        setState(() => _isSendingOtp = false);
      }
    }
  }

  Future<void> _handleOtpVerified() async {
    final session = Supabase.instance.client.auth.currentSession;
    final user = Supabase.instance.client.auth.currentUser;
    _kycFlowLog('OTP verified callback. session=${session != null} userId=${user?.id} phone=${user?.phone} email=${user?.email}');
    if (user != null) {
      try {
        final row = await Supabase.instance.client
            .from('users')
            .select('id,email,phone,full_name,country,state,is_verified,created_at,updated_at')
            .eq('id', user.id)
            .maybeSingle();
        _kycFlowLog('public.users lookup after OTP for userId=${user.id}: $row');
      } catch (err) {
        _kycFlowLog('public.users lookup after OTP failed: $err');
      }
    }
    await _showIslandMessage('Tu número ha sido verificado');
    await _showIslandMessage('Bienvenido a Call a Vet');
    if (!mounted) return;
    setState(() {
      _showIsland = false;
      _islandText = '';
      _islandOpacity = 0;
    });
    _goNext();
  }

  Future<void> _handleProfileContinue({
    required String fullName,
    required String email,
    required String countryCode,
    required String state,
  }) async {
    if (_isSavingProfile) return;
    final user = Supabase.instance.client.auth.currentUser;
    _kycFlowLog('Profile submit started. userId=${user?.id} emailInput=${email.trim().toLowerCase()} stateInput=${state.trim()} countryInput=${countryCode.trim().toUpperCase()}');
    if (user == null) {
      _kycFlowLog('Profile submit aborted: no active auth user/session');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay sesión activa.')),
      );
      return;
    }
    setState(() => _isSavingProfile = true);
    try {
      final normalizedEmail = email.trim().toLowerCase();
      await _sendAuthEmailConfirmationIfNeeded(normalizedEmail);

      final updatePayload = {
        'full_name': fullName.trim(),
        'email': normalizedEmail,
        'country': countryCode.trim().toUpperCase(),
        'state': state.trim(),
      };
      _kycFlowLog('Updating public.users with payload=$updatePayload for userId=${user.id}');
      final updatedRow = await Supabase.instance.client
          .from('users')
          .update(updatePayload)
          .eq('id', user.id)
          .select('id,email,phone,full_name,country,state,is_verified,updated_at')
          .maybeSingle();
      _kycFlowLog('public.users update result for userId=${user.id}: $updatedRow');
      _goNext();
    } on PostgrestException catch (err) {
      _kycFlowLog('Profile update PostgrestException: code=${err.code} message=${err.message} details=${err.details} hint=${err.hint}');
      if (!mounted) return;
      final message = (err.message).toLowerCase();
      final isDuplicateEmail =
          message.contains('users_email_key') || message.contains('duplicate key');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isDuplicateEmail
                ? 'Ese correo ya está registrado. Usa otro correo para continuar.'
                : 'No se pudo guardar tus datos: ${err.message}',
          ),
        ),
      );
    } catch (err) {
      _kycFlowLog('Profile update error: $err');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo guardar tus datos: $err')),
      );
    } finally {
      if (mounted) {
        setState(() => _isSavingProfile = false);
      }
    }
  }

  Future<void> _sendAuthEmailConfirmationIfNeeded(String rawEmail) async {
    final email = rawEmail.trim().toLowerCase();
    if (email.isEmpty) return;

    final client = Supabase.instance.client;
    final currentUser = client.auth.currentUser;
    if (currentUser == null) {
      _kycFlowLog('Skipping auth email confirmation request: no active auth user');
      return;
    }

    final currentEmail = (currentUser.email ?? '').trim().toLowerCase();
    final isAlreadyVerified = currentUser.emailConfirmedAt != null;
    if (currentEmail == email && isAlreadyVerified) {
      _kycFlowLog('Auth email already linked and verified: $email');
      return;
    }

    try {
      await _requestEmailConfirmationViaGateway(email);
      _kycFlowLog('Requested Supabase confirmation email via gateway for auth.users email=$email');
      unawaited(_showIslandMessage('te enviamos un correo para confirmar tu email'));
      return;
    } catch (err) {
      _kycFlowLog('Gateway confirmation request failed, falling back app-side for $email: $err');
    }

    try {
      await client.auth.updateUser(
        UserAttributes(email: email),
      );
      _kycFlowLog('Requested Supabase confirmation email for auth.users email=$email');
      unawaited(_showIslandMessage('te enviamos un correo para confirmar tu email'));
    } catch (err) {
      _kycFlowLog('Failed requesting Supabase confirmation email for $email: $err');
    }
  }

  Future<void> _requestEmailConfirmationViaGateway(String email) async {
    final sessionToken = Supabase.instance.client.auth.currentSession?.accessToken;
    if (sessionToken == null || sessionToken.isEmpty) {
      throw StateError('missing auth session token for gateway email confirmation request');
    }

    final uri = Uri.parse('${Environment.apiBaseUrl}/auth/otp/email/confirm-request');
    final http = HttpClient();
    try {
      final req = await http.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $sessionToken');
      req.add(utf8.encode(jsonEncode({'email': email})));

      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError(
          'gateway email confirmation request failed status=${res.statusCode} body=$body',
        );
      }
    } finally {
      http.close(force: true);
    }
  }

  Future<void> _showIslandMessage(String text) async {
    if (!mounted) return;
    setState(() {
      _showIsland = true;
      _islandText = text;
      _islandOpacity = 0;
    });
    await Future.delayed(const Duration(milliseconds: 30));
    if (!mounted) return;
    setState(() => _islandOpacity = 1);
    await Future.delayed(const Duration(milliseconds: 1000));
    if (!mounted) return;
    setState(() => _islandOpacity = 0);
    await Future.delayed(const Duration(milliseconds: 280));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101010),
      body: Stack(
        children: [
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IgnorePointer(
                        ignoring: _pageIndex == 0,
                        child: Opacity(
                          opacity: _pageIndex == 0 ? 0 : 1,
                          child: TextButton(
                            onPressed: _goBack,
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                            ),
                            child: const Text(
                              'atrás',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontFamily: 'ABC Diatype',
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => context.go('/home'),
                        style: TextButton.styleFrom(foregroundColor: Colors.white),
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
                    ],
                  ),
                  Expanded(
                    child: PageView(
                      controller: _pageController,
                      onPageChanged: (i) => setState(() => _pageIndex = i),
                      children: [
                        _KycPhoneScreen(
                          phoneController: _phoneController,
                          isSending: _isSendingOtp,
                          onSubmitPhone: _handlePhoneContinue,
                        ),
                        if (!_bypassOtpValidationForDev)
                          _KycOtpScreen(
                            phoneE164: _e164Phone,
                            isActive: _pageIndex == 1,
                            onVerified: () {
                              unawaited(_handleOtpVerified());
                            },
                          ),
                        _KycProfileScreen(
                          nameController: _nameController,
                          emailController: _emailController,
                          stateController: _stateController,
                          isSaving: _isSavingProfile,
                          onSubmit: _handleProfileContinue,
                        ),
                        _KycPlaceholderScreen(
                          title: 'preguntas rápidas',
                          description: 'responde tres preguntas para completar tu perfil.',
                          onNext: _goNext,
                        ),
                        _KycPlaceholderScreen(
                          title: 'todo listo',
                          description: 'confirmación antes de ver los planes.',
                          onNext: _goNext,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_showIsland)
            Positioned(
              top: MediaQuery.of(context).padding.top + 6,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeOut,
                      opacity: _islandOpacity,
                      child: Text(
                        _islandText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontFamily: 'ABC Diatype',
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _KycPhoneScreen extends StatefulWidget {
  const _KycPhoneScreen({
    required this.phoneController,
    required this.onSubmitPhone,
    required this.isSending,
  });

  final TextEditingController phoneController;
  final ValueChanged<String> onSubmitPhone;
  final bool isSending;

  @override
  State<_KycPhoneScreen> createState() => _KycPhoneScreenState();
}

class _KycPhoneScreenState extends State<_KycPhoneScreen> {
  String _countryCode = 'MX';
  String _dialCode = '52';
  String _flagEmoji = '🇲🇽';
  Timer? _debounce;
  bool _isValid = false;
  String? _normalizedPhone;
  CountryWithPhoneCode? _selectedCountryData;

  @override
  void initState() {
    super.initState();
    _initPhoneLibrary();
  }

  void _pickCountry() {
    final screenHeight = MediaQuery.of(context).size.height;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          height: screenHeight * 0.82,
          margin: const EdgeInsets.fromLTRB(0, 24, 0, 24),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment(0.50, -0.00),
              end: Alignment(0.50, 1.00),
              colors: [Color(0xFF101010), Color(0xFF070707)],
            ),
            borderRadius: BorderRadius.circular(35),
          ),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Theme(
            data: Theme.of(context).copyWith(
              dividerTheme: const DividerThemeData(
                color: Colors.white,
                thickness: 1,
              ),
            ),
            child: CountryListView(
              onSelect: (country) {
                setState(() {
                  _countryCode = country.countryCode;
                  _dialCode = country.phoneCode;
                  _flagEmoji = country.flagEmoji;
                });
                _syncSelectedCountryData();
                _scheduleValidation();
              },
              favorite: const ['MX', 'US'],
              showPhoneCode: true,
              countryListTheme: const CountryListThemeData(
                textStyle: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontFamily: 'ABC Diatype',
                  fontWeight: FontWeight.w500,
                ),
                searchTextStyle: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontFamily: 'ABC Diatype',
                  fontWeight: FontWeight.w500,
                ),
                inputDecoration: InputDecoration(
                  hintText: 'buscar país',
                  hintStyle: TextStyle(
                    color: Color(0x99FFFFFF),
                    fontSize: 14,
                    fontFamily: 'ABC Diatype',
                    fontWeight: FontWeight.w400,
                  ),
                  prefixIcon: Icon(Icons.search, color: Color(0x88FFFFFF)),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Color(0x44FFFFFF)),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white),
                  ),
                  border: UnderlineInputBorder(
                    borderSide: BorderSide(color: Color(0x44FFFFFF)),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _initPhoneLibrary() async {
    await init(overrides: {
      'MX': _buildMexicoOverride(),
    });
    _syncSelectedCountryData();
    _scheduleValidation();
  }

  CountryWithPhoneCode _buildMexicoOverride() {
    return CountryWithPhoneCode(
      countryCode: 'MX',
      phoneCode: '52',
      countryName: 'Mexico',
      exampleNumberMobileNational: '55 1234 5678',
      exampleNumberFixedLineNational: '55 1234 5678',
      phoneMaskMobileNational: '00 0000 0000',
      phoneMaskFixedLineNational: '00 0000 0000',
      exampleNumberMobileInternational: '+52 55 1234 5678',
      exampleNumberFixedLineInternational: '+52 55 1234 5678',
      phoneMaskMobileInternational: '+00 00 0000 0000',
      phoneMaskFixedLineInternational: '+00 00 0000 0000',
    );
  }

  void _syncSelectedCountryData() {
    final countries = CountryManager().countries;
    if (countries.isEmpty) return;
    final match = countries.firstWhere(
      (country) => country.countryCode.toUpperCase() == _countryCode,
      orElse: () => countries.first,
    );
    if (_selectedCountryData?.countryCode != match.countryCode) {
      setState(() => _selectedCountryData = match);
    }
  }

  void _scheduleValidation() {
    _debounce?.cancel();
    final rawText = widget.phoneController.text.trim();
    if (rawText.isEmpty) {
      if (_isValid || _normalizedPhone != null) {
        setState(() {
          _isValid = false;
          _normalizedPhone = null;
        });
      }
      return;
    }
    final country = _selectedCountryData;
    if (country == null) {
      if (_isValid) {
        setState(() => _isValid = false);
      }
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final number = rawText.replaceAll(RegExp(r'\s+'), '');
      bool isValid;
      String? normalized;
      try {
        final result = await getFormattedParseResult(
          number,
          country,
          phoneNumberFormat: PhoneNumberFormat.international,
        );
        isValid = result != null && result.e164.isNotEmpty;
        normalized = result?.e164;
      } catch (_) {
        isValid = false;
        normalized = null;
      }
      if (!mounted) return;
      if (_isValid != isValid || _normalizedPhone != normalized) {
        setState(() {
          _isValid = isValid;
          _normalizedPhone = normalized;
        });
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 40, bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(
                  width: 351,
                  child: Text(
                    'introduce tu número de teléfono para crear tu cuenta. '
                    'te mandaremos un código de confirmación para continuar.',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontFamily: 'ABC Diatype',
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    InkWell(
                      onTap: _pickCountry,
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        width: 94,
                        height: 62,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 25,
                              height: 25,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFF2E2E2E),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                _flagEmoji,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '+$_dialCode',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontFamily: 'ABC Diatype',
                                fontWeight: FontWeight.w400,
                                height: 1.85,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        height: 62,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        alignment: Alignment.centerLeft,
                        child: TextField(
                          controller: widget.phoneController,
                          keyboardType: TextInputType.phone,
                          onChanged: (_) => _scheduleValidation(),
                          inputFormatters: _selectedCountryData == null
                              ? null
                              : [
                                  LibPhonenumberTextFormatter(
                                    country: _selectedCountryData!,
                                    phoneNumberType: PhoneNumberType.mobile,
                                    phoneNumberFormat: PhoneNumberFormat.national,
                                    inputContainsCountryCode: false,
                                  ),
                                ],
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontFamily: 'ABC Diatype',
                            fontWeight: FontWeight.w500,
                          ),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            hintText: '55 1234 5678',
                            hintStyle: TextStyle(
                              color: Color(0x99FFFFFF),
                              fontSize: 16,
                              fontFamily: 'ABC Diatype',
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const SizedBox(
                  width: 351,
                  child: Text(
                    'si ya tienes una cuenta con nosotros, iniciarás sesión con '
                    'el mismo código de confirmación.',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontFamily: 'ABC Diatype',
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: SizedBox(
            width: double.infinity,
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.phoneController,
              builder: (context, value, child) {
                final hasInput = value.text.trim().isNotEmpty;
                final isEnabled = hasInput && _isValid && _normalizedPhone != null;
                return ElevatedButton(
                  onPressed: isEnabled && !widget.isSending
                      ? () => widget.onSubmitPhone(_normalizedPhone!)
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF101010),
                    disabledBackgroundColor: Colors.white.withOpacity(0.2),
                    disabledForegroundColor: Colors.white.withOpacity(0.6),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                    ),
                  ),
                  child: widget.isSending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Color(0xFF101010),
                            ),
                          ),
                        )
                      : const Text(
                          'continuar',
                          style: TextStyle(
                            fontSize: 14,
                            fontFamily: 'ABC Diatype',
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _KycProfileScreen extends StatefulWidget {
  const _KycProfileScreen({
    required this.nameController,
    required this.emailController,
    required this.stateController,
    required this.isSaving,
    required this.onSubmit,
  });

  final TextEditingController nameController;
  final TextEditingController emailController;
  final TextEditingController stateController;
  final bool isSaving;
  final Future<void> Function({
    required String fullName,
    required String email,
    required String countryCode,
    required String state,
  }) onSubmit;

  @override
  State<_KycProfileScreen> createState() => _KycProfileScreenState();
}

class _KycProfileScreenState extends State<_KycProfileScreen> {
  bool _stateAutofillAttempted = false;
  String? _locationDebugText;

  @override
  void initState() {
    super.initState();
    _preselectStateFromLocation();
  }

  bool get _isEmailValid {
    final value = widget.emailController.text.trim();
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value);
  }

  bool get _canContinue {
    return widget.nameController.text.trim().isNotEmpty &&
        widget.stateController.text.trim().isNotEmpty &&
        _isEmailValid;
  }

  Future<void> _preselectStateFromLocation() async {
    if (_stateAutofillAttempted || widget.stateController.text.trim().isNotEmpty) {
      return;
    }
    _stateAutofillAttempted = true;
    _kycLog('Starting location preselection');
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      _kycLog('Location service enabled: $serviceEnabled');
      if (!serviceEnabled) {
        if (mounted) {
          setState(() => _locationDebugText = 'Ubicación desactivada en el dispositivo.');
        }
        return;
      }

      var permission = await Geolocator.checkPermission();
      _kycLog('Initial permission: $permission');
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        _kycLog('Requested permission result: $permission');
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() => _locationDebugText = 'Permiso de ubicación no concedido.');
        }
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
        ),
      );
      _kycLog('Coordinates: ${position.latitude}, ${position.longitude}');

      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );
      if (placemarks.isEmpty) {
        if (mounted) {
          setState(() => _locationDebugText = 'No se pudo resolver estado por coordenadas.');
        }
        return;
      }

      final first = placemarks.first;
      _kycLog(
        'Placemark admin="${first.administrativeArea}" subAdmin="${first.subAdministrativeArea}" locality="${first.locality}" country="${first.country}"',
      );

      final candidates = [
        first.administrativeArea,
        first.subAdministrativeArea,
        first.locality,
      ];
      for (final candidate in candidates) {
        final value = candidate?.trim();
        if (value == null || value.isEmpty) continue;
        final matched = _matchMexicanState(value);
        _kycLog('Candidate "$value" => matched "$matched"');
        if (matched != null) {
          if (!mounted) return;
          setState(() {
            widget.stateController.text = matched;
            _locationDebugText = 'Estado detectado: $matched';
          });
          return;
        }
      }
      if (mounted) {
        setState(
          () => _locationDebugText =
              'No se detectó un estado de México. Selecciónalo manualmente.',
        );
      }
    } catch (err) {
      _kycLog('Location preselection error: $err');
      if (mounted) {
        setState(() => _locationDebugText = 'Error de ubicación: $err');
      }
      return;
    }
  }

  void _pickMexicanState() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF101010),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: ListView.separated(
            itemCount: _mexicanStates.length,
            separatorBuilder: (_, __) => Divider(
              color: Colors.white.withOpacity(0.08),
              height: 1,
            ),
            itemBuilder: (context, index) {
              final state = _mexicanStates[index];
              final isSelected = widget.stateController.text.trim() == state;
              return ListTile(
                onTap: () {
                  setState(() => widget.stateController.text = state);
                  Navigator.of(context).pop();
                },
                title: Text(
                  state,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontFamily: 'ABC Diatype',
                    fontWeight: isSelected ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
                trailing: isSelected
                    ? const Icon(Icons.check, color: Colors.white, size: 18)
                    : null,
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _submit() async {
    if (!_canContinue || widget.isSaving) return;
    await widget.onSubmit(
      fullName: widget.nameController.text,
      email: widget.emailController.text,
      countryCode: 'MX',
      state: widget.stateController.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.nameController,
      builder: (_, __, ___) {
        return ValueListenableBuilder<TextEditingValue>(
          valueListenable: widget.emailController,
          builder: (_, __, ___) {
            return ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.stateController,
              builder: (_, __, ___) {
                return Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.only(top: 40, bottom: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(
                              width: 351,
                              child: Text(
                                'cuéntanos de ti.',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontFamily: 'ABC Diatype',
                                  fontWeight: FontWeight.w500,
                                  height: 1.10,
                                ),
                              ),
                            ),
                            const SizedBox(height: 34),
                            const Text(
                              '¿cuál es tu nombre completo?',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontFamily: 'ABC Diatype',
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                            const SizedBox(height: 10),
                            _KycInputField(
                              controller: widget.nameController,
                              hint: 'escribe tu nombre aquí',
                              keyboardType: TextInputType.name,
                            ),
                            const SizedBox(height: 36),
                            const Text(
                              '¿cuál es tu correo electrónico?',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontFamily: 'ABC Diatype',
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                            const SizedBox(height: 10),
                            _KycInputField(
                              controller: widget.emailController,
                              hint: 'escribe tu nombre aquí',
                              keyboardType: TextInputType.emailAddress,
                            ),
                            const SizedBox(height: 36),
                            const Text(
                              'call a vet es un servicio exclusivo para México. dónde\nestás ubicado?',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontFamily: 'ABC Diatype',
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                            const SizedBox(height: 10),
                            InkWell(
                              onTap: _pickMexicanState,
                              borderRadius: BorderRadius.circular(20),
                              child: IgnorePointer(
                                child: _KycInputField(
                                  controller: widget.stateController,
                                  hint: 'selecciona una opción',
                                  keyboardType: TextInputType.text,
                                  trailingIcon: const Icon(
                                    Icons.keyboard_arrow_down,
                                    color: Color(0xFF3A3A3A),
                                    size: 20,
                                  ),
                                ),
                              ),
                            ),
                            if (_kycLocationDebug && _locationDebugText != null) ...[
                              const SizedBox(height: 8),
                              SelectableText(
                                _locationDebugText!,
                                style: const TextStyle(
                                  color: Color(0x99FFFFFF),
                                  fontSize: 11,
                                  fontFamily: 'ABC Diatype',
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          const Text(
                            'continuar',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontFamily: 'ABC Diatype',
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 45,
                            height: 45,
                            child: ElevatedButton(
                              onPressed: (_canContinue && !widget.isSaving) ? _submit : null,
                              style: ElevatedButton.styleFrom(
                                shape: const CircleBorder(),
                                padding: EdgeInsets.zero,
                                backgroundColor: Colors.white,
                                foregroundColor: const Color(0xFF101010),
                                disabledBackgroundColor: Colors.white.withOpacity(0.2),
                                disabledForegroundColor: Colors.white.withOpacity(0.6),
                              ),
                              child: widget.isSaving
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor: AlwaysStoppedAnimation<Color>(
                                          Color(0xFF101010),
                                        ),
                                      ),
                                    )
                                  : const Icon(Icons.arrow_forward, size: 18),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

class _KycInputField extends StatelessWidget {
  const _KycInputField({
    required this.controller,
    required this.hint,
    required this.keyboardType,
    this.trailingIcon,
  });

  final TextEditingController controller;
  final String hint;
  final TextInputType keyboardType;
  final Widget? trailingIcon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 62,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(20),
      ),
      alignment: Alignment.centerLeft,
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontFamily: 'ABC Diatype',
          fontWeight: FontWeight.w400,
        ),
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: hint,
          suffixIcon: trailingIcon,
          hintStyle: const TextStyle(
            color: Color(0xFF3A3A3A),
            fontSize: 15,
            fontFamily: 'ABC Diatype',
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _KycPlaceholderScreen extends StatelessWidget {
  const _KycPlaceholderScreen({
    required this.title,
    required this.description,
    required this.onNext,
  });

  final String title;
  final String description;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              description,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: onNext,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF101010),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: const Text(
                'continuar',
                style: TextStyle(
                  fontSize: 14,
                  fontFamily: 'ABC Diatype',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KycOtpScreen extends StatefulWidget {
  const _KycOtpScreen({
    required this.phoneE164,
    required this.isActive,
    required this.onVerified,
  });

  final String? phoneE164;
  final bool isActive;
  final VoidCallback onVerified;

  @override
  State<_KycOtpScreen> createState() => _KycOtpScreenState();
}

class _KycOtpScreenState extends State<_KycOtpScreen> {
  final _codeController = TextEditingController();
  final _otpFocusNode = FocusNode();
  bool _isVerifying = false;
  bool _isResending = false;
  String? _errorText;
  Timer? _resendTimer;
  int _resendSecondsLeft = 60;

  @override
  void initState() {
    super.initState();
    _startResendCooldown();
    _requestOtpFocus();
  }

  @override
  void didUpdateWidget(covariant _KycOtpScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _requestOtpFocus();
    }
  }

  void _requestOtpFocus() {
    Future.delayed(const Duration(milliseconds: 120), () {
      if (!mounted || !widget.isActive) return;
      FocusScope.of(context).requestFocus(_otpFocusNode);
    });
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    _codeController.dispose();
    _otpFocusNode.dispose();
    super.dispose();
  }

  void _startResendCooldown() {
    _resendTimer?.cancel();
    setState(() => _resendSecondsLeft = 60);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendSecondsLeft <= 1) {
        timer.cancel();
        setState(() => _resendSecondsLeft = 0);
        return;
      }
      setState(() => _resendSecondsLeft -= 1);
    });
  }

  Future<void> _verifyCode() async {
    final phone = widget.phoneE164;
    final code = _codeController.text.trim();
    if (phone == null || phone.isEmpty) {
      setState(() => _errorText = 'falta el número de teléfono.');
      return;
    }
    if (code.length < 6) {
      setState(() => _errorText = 'ingresa los 6 dígitos.');
      return;
    }
    setState(() {
      _isVerifying = true;
      _errorText = null;
    });
    try {
      final client = Supabase.instance.client;
      _kycFlowLog('Verifying OTP for phone=$phone codeLength=${code.length}');
      final result = await client.auth.verifyOTP(
        type: OtpType.sms,
        token: code,
        phone: phone,
      );
      _kycFlowLog('verifyOTP success. session=${result.session != null} userId=${result.user?.id} phone=${result.user?.phone} email=${result.user?.email}');
      final currentUser = client.auth.currentUser;
      final currentSession = client.auth.currentSession;
      _kycFlowLog('Post-verify currentSession=${currentSession != null} currentUserId=${currentUser?.id}');
      widget.onVerified();
    } on AuthException catch (err) {
      _kycFlowLog('verifyOTP AuthException: ${err.message}');
      setState(() => _errorText = err.message);
    } catch (err) {
      _kycFlowLog('verifyOTP error: $err');
      setState(() => _errorText = 'no se pudo verificar: $err');
    } finally {
      if (mounted) {
        setState(() => _isVerifying = false);
      }
    }
  }

  Future<void> _resendCode() async {
    if (_resendSecondsLeft > 0 || _isResending) return;
    final phone = widget.phoneE164;
    if (phone == null || phone.isEmpty) {
      setState(() => _errorText = 'falta el número de teléfono.');
      return;
    }
    final normalizedPhone = _normalizePhoneForOtp(phone);
    final guardRetryAfter = _OtpAttemptGuard.retryAfter(normalizedPhone);
    if (guardRetryAfter != null) {
      final minutes = guardRetryAfter.inMinutes;
      final seconds = guardRetryAfter.inSeconds % 60;
      final waitText = minutes > 0 ? '${minutes}m ${seconds}s' : '${seconds}s';
      setState(() => _errorText = 'demasiados intentos. intenta de nuevo en $waitText.');
      return;
    }
    setState(() {
      _isResending = true;
      _errorText = null;
    });
    try {
      final client = Supabase.instance.client;
      _kycFlowLog('Resending OTP for phone=$normalizedPhone');
      await client.auth.signInWithOtp(
        phone: normalizedPhone,
        shouldCreateUser: true,
        channel: OtpChannel.sms,
      );
      _kycFlowLog('Resend OTP accepted by Supabase for phone=$normalizedPhone');
      _OtpAttemptGuard.register(normalizedPhone);
      if (!mounted) return;
      _startResendCooldown();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('código reenviado.')),
      );
    } on AuthException catch (err) {
      _kycFlowLog('Resend OTP AuthException: ${err.message}');
      setState(() => _errorText = err.message);
    } catch (err) {
      _kycFlowLog('Resend OTP error: $err');
      setState(() => _errorText = 'no se pudo reenviar: $err');
    } finally {
      if (mounted) {
        setState(() => _isResending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 40, bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(
                  width: 351,
                  child: Text(
                    'introduce el código de confirmación:',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontFamily: 'ABC Diatype',
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (widget.phoneE164 != null && widget.phoneE164!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'enviado a ${widget.phoneE164}',
                      style: const TextStyle(
                        color: Color(0x99FFFFFF),
                        fontSize: 12,
                        fontFamily: 'ABC Diatype',
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _OtpGroupBox(
                          digits: _codeController.text,
                          startIndex: 0,
                        ),
                        const SizedBox(width: 20),
                        _OtpGroupBox(
                          digits: _codeController.text,
                          startIndex: 3,
                        ),
                      ],
                    ),
                    Opacity(
                      opacity: 0,
                      child: TextField(
                        controller: _codeController,
                        focusNode: _otpFocusNode,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_errorText != null)
                  Text(
                    _errorText!,
                    style: const TextStyle(
                      color: Color(0xFFFF8A80),
                      fontSize: 12,
                      fontFamily: 'ABC Diatype',
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                TextButton(
                  onPressed: (_resendSecondsLeft == 0 && !_isResending)
                      ? _resendCode
                      : null,
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: Text(
                    _isResending
                        ? 'reenviando...'
                        : _resendSecondsLeft > 0
                            ? 'reenviar código (${_resendSecondsLeft}s)'
                            : 'reenviar código',
                    style: TextStyle(
                      color: (_resendSecondsLeft == 0 && !_isResending)
                          ? Colors.white
                          : const Color(0x99FFFFFF),
                      fontSize: 12,
                      fontFamily: 'ABC Diatype',
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: (!_isVerifying && _codeController.text.trim().length == 6)
                  ? _verifyCode
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF101010),
                disabledBackgroundColor: Colors.white.withOpacity(0.2),
                disabledForegroundColor: Colors.white.withOpacity(0.6),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                ),
              ),
              child: _isVerifying
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Color(0xFF101010),
                        ),
                      ),
                    )
                  : const Text(
                      'continuar',
                      style: TextStyle(
                        fontSize: 14,
                        fontFamily: 'ABC Diatype',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

class _OtpGroupBox extends StatelessWidget {
  const _OtpGroupBox({
    required this.digits,
    required this.startIndex,
  });

  final String digits;
  final int startIndex;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 148,
      height: 62,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(3, (index) {
          final digitIndex = startIndex + index;
          final value = digitIndex < digits.length ? digits[digitIndex] : '';
          return _OtpDigitSlot(value: value, isActive: digitIndex == digits.length);
        }),
      ),
    );
  }
}

class _OtpDigitSlot extends StatelessWidget {
  const _OtpDigitSlot({
    required this.value,
    required this.isActive,
  });

  final String value;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 25,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            height: 1,
            color: isActive ? Colors.white : const Color(0xFF3A3A3A),
          ),
        ],
      ),
    );
  }
}
