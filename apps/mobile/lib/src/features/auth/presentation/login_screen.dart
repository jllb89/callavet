import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:country_picker/country_picker.dart';
import 'package:cav_mobile/src/core/config/environment.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_libphonenumber/flutter_libphonenumber.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const bool _loginFlowDebug = bool.fromEnvironment(
  'KYC_FLOW_DEBUG',
  defaultValue: false,
);
const bool _bypassOtpValidationForDev = bool.fromEnvironment(
  'BYPASS_OTP',
  defaultValue: false,
);

void _loginLog(String message) {
  if (_loginFlowDebug) {
    debugPrint('[Login][Flow] $message');
  }
}

String _normalizePhone(String input) {
  final compact = input.replaceAll(RegExp(r'[^0-9+]'), '');
  if (compact.startsWith('+')) return compact;
  final digits = compact.replaceAll(RegExp(r'[^0-9]'), '');
  return '+$digits';
}

String _digitsOnly(String input) => input.replaceAll(RegExp(r'[^0-9]'), '');

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  final _otpFocusNode = FocusNode();
  String _countryCode = 'MX';
  String _dialCode = '52';
  String _flagEmoji = '🇲🇽';
  CountryWithPhoneCode? _selectedCountryData;
  bool _isPhoneValid = false;
  String? _normalizedPhone;
  Timer? _phoneValidationDebounce;
  Timer? _emailValidationDebounce;
  Timer? _resendTimer;

  int _step = 0;
  String? _phoneE164;
  String? _emailForOtp;
  String _otpChannel = 'sms';
  int _resendSecondsLeft = 0;
  String? _existingUserId;
  bool _isSendingOtp = false;
  bool _isVerifyingOtp = false;
  String? _errorText;
  bool _gatewayOtpUnavailable = false;
  bool _showEmailValidationError = false;
  bool _showIsland = false;
  String _islandText = '';
  double _islandOpacity = 0;

  @override
  void initState() {
    super.initState();
    _initPhoneLibrary();
  }

  @override
  void dispose() {
    _phoneValidationDebounce?.cancel();
    _emailValidationDebounce?.cancel();
    _resendTimer?.cancel();
    _phoneController.dispose();
    _emailController.dispose();
    _otpController.dispose();
    _otpFocusNode.dispose();
    super.dispose();
  }

  Future<void> _initPhoneLibrary() async {
    await init(overrides: {'MX': _buildMexicoOverride()});
    _syncSelectedCountryData();
    if (mounted) {
      setState(() {});
    }
    _schedulePhoneValidation();
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
    _selectedCountryData = match;
  }

  void _schedulePhoneValidation() {
    _phoneValidationDebounce?.cancel();

    final rawText = _phoneController.text.trim();
    if (rawText.isEmpty) {
      if (_isPhoneValid || _normalizedPhone != null) {
        setState(() {
          _isPhoneValid = false;
          _normalizedPhone = null;
        });
      }
      return;
    }

    final country = _selectedCountryData;
    if (country == null) {
      if (_isPhoneValid || _normalizedPhone != null) {
        setState(() {
          _isPhoneValid = false;
          _normalizedPhone = null;
        });
      }
      return;
    }

    _phoneValidationDebounce = Timer(const Duration(milliseconds: 300), () async {
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
      if (_isPhoneValid != isValid || _normalizedPhone != normalized) {
        setState(() {
          _isPhoneValid = isValid;
          _normalizedPhone = normalized;
        });
      }
    });
  }

  bool _isValidEmail(String input) {
    final email = input.trim();
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);
  }

  void _scheduleEmailValidation() {
    _emailValidationDebounce?.cancel();
    if (_showEmailValidationError) {
      setState(() => _showEmailValidationError = false);
    }
    final text = _emailController.text.trim();
    if (text.isEmpty) return;

    _emailValidationDebounce = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      final shouldShow = _emailController.text.trim().isNotEmpty &&
          !_isValidEmail(_emailController.text.trim());
      if (_showEmailValidationError != shouldShow) {
        setState(() => _showEmailValidationError = shouldShow);
      }
    });
  }

  void _startResendCooldown([int seconds = 60]) {
    _resendTimer?.cancel();
    setState(() => _resendSecondsLeft = seconds);
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

  String _retryMessage(String message, int? retryAfterSeconds) {
    if (retryAfterSeconds == null || retryAfterSeconds <= 0) return message;
    final minutes = retryAfterSeconds ~/ 60;
    final seconds = retryAfterSeconds % 60;
    final waitText = minutes > 0 ? '${minutes}m ${seconds}s' : '${seconds}s';
    return '$message (intenta de nuevo en $waitText)';
  }

  Future<Map<String, dynamic>> _gatewayPost(String path, Map<String, dynamic> body) async {
    final uri = Uri.parse('${Environment.apiBaseUrl}$path');
    final client = HttpClient();
    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.add(utf8.encode(jsonEncode(body)));

      final res = await req.close();
      final text = await utf8.decoder.bind(res).join();
      final data = text.isEmpty ? <String, dynamic>{} : (jsonDecode(text) as Map<String, dynamic>);

      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw _GatewayOtpException(
          message: data['message']?.toString() ?? 'No se pudo completar la solicitud.',
          code: data['code']?.toString(),
          retryAfterSeconds: (data['retryAfterSeconds'] as num?)?.toInt(),
          statusCode: (data['statusCode'] as num?)?.toInt() ?? res.statusCode,
        );
      }
      return data;
    } finally {
      client.close(force: true);
    }
  }

  bool _isGatewayRouteMissing(_GatewayOtpException err) {
    final msg = err.message.toLowerCase();
    return (err.statusCode == 404) &&
        (msg.contains('cannot post /auth/otp/') ||
            msg.contains('cannot post /api/auth/otp/') ||
            msg.contains('cannot post /v1/auth/otp/'));
  }

  Future<Map<String, dynamic>> _sendOtpDirectSupabase({
    required String channel,
    String? phone,
    String? email,
  }) async {
    final client = Supabase.instance.client;
    if (channel == 'sms') {
      await client.auth.signInWithOtp(
        phone: phone,
        shouldCreateUser: false,
        channel: OtpChannel.sms,
      );
    } else {
      await client.auth.signInWithOtp(
        email: email,
        shouldCreateUser: false,
      );
    }
    return {
      'ok': true,
      'cooldownSeconds': 60,
      'message': channel == 'sms' ? 'Código enviado por SMS.' : 'Código enviado a tu correo.',
    };
  }

  Future<Map<String, dynamic>> _sendOtpViaGateway({
    required String channel,
    String? phone,
    String? email,
  }) async {
    if (_gatewayOtpUnavailable) {
      return _sendOtpDirectSupabase(channel: channel, phone: phone, email: email);
    }
    try {
      return await _gatewayPost('/auth/otp/send', {
        'channel': channel,
        if (phone != null) 'phone': phone,
        if (email != null) 'email': email,
        'shouldCreateUser': false,
      });
    } on _GatewayOtpException catch (err) {
      if (_isGatewayRouteMissing(err)) {
        _loginLog('Gateway OTP routes unavailable on this env. Falling back to direct Supabase OTP.');
        _gatewayOtpUnavailable = true;
        return _sendOtpDirectSupabase(channel: channel, phone: phone, email: email);
      }
      rethrow;
    }
  }

  Future<void> _checkVerifyLock() async {
    if (_gatewayOtpUnavailable) return;
    final destination = _otpChannel == 'sms' ? _phoneE164 : _emailForOtp;
    if (destination == null || destination.isEmpty) return;
    try {
      await _gatewayPost('/auth/otp/verify-lock', {
        'channel': _otpChannel,
        if (_otpChannel == 'sms') 'phone': destination,
        if (_otpChannel == 'email') 'email': destination,
      });
    } on _GatewayOtpException catch (err) {
      if (_isGatewayRouteMissing(err)) {
        _loginLog('Gateway verify-lock route unavailable. Continuing without server-side lock checks.');
        _gatewayOtpUnavailable = true;
        return;
      }
      rethrow;
    }
  }

  Future<void> _recordVerifyAttempt(bool success) async {
    if (_gatewayOtpUnavailable) return;
    final destination = _otpChannel == 'sms' ? _phoneE164 : _emailForOtp;
    if (destination == null || destination.isEmpty) return;
    try {
      await _gatewayPost('/auth/otp/verify-attempt', {
        'channel': _otpChannel,
        if (_otpChannel == 'sms') 'phone': destination,
        if (_otpChannel == 'email') 'email': destination,
        'success': success,
      });
    } on _GatewayOtpException catch (err) {
      if (_isGatewayRouteMissing(err)) {
        _loginLog('Gateway verify-attempt route unavailable. Skipping verify-attempt tracking.');
        _gatewayOtpUnavailable = true;
        return;
      }
    } catch (_) {
      // no-op for analytics/guardrail write failures
    }
  }

  void _pickCountry() {
    showCountryPicker(
      context: context,
      countryListTheme: CountryListThemeData(
        backgroundColor: const Color(0xFF101010),
        borderRadius: BorderRadius.circular(24),
        textStyle: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontFamily: 'ABC Diatype',
          fontWeight: FontWeight.w500,
        ),
        searchTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontFamily: 'ABC Diatype',
          fontWeight: FontWeight.w500,
        ),
        inputDecoration: const InputDecoration(
          hintText: 'buscar país',
          hintStyle: TextStyle(
            color: Color(0x99FFFFFF),
            fontSize: 14,
            fontFamily: 'ABC Diatype',
            fontWeight: FontWeight.w400,
          ),
          enabledBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: Color(0x44FFFFFF)),
          ),
          focusedBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: Colors.white),
          ),
        ),
      ),
      favorite: const ['MX', 'US'],
      showPhoneCode: true,
      onSelect: (country) {
        setState(() {
          _countryCode = country.countryCode;
          _dialCode = country.phoneCode;
          _flagEmoji = country.flagEmoji;
        });
        _syncSelectedCountryData();
        _schedulePhoneValidation();
      },
    );
  }

  Future<bool> _phoneExists(String phoneInput) async {
    final client = Supabase.instance.client;
    final e164 = _normalizePhone(phoneInput);
    final digits = _digitsOnly(e164);
    _loginLog('Checking existing user by phone. e164=$e164 digits=$digits');

    final byDigits = await client
        .from('users')
        .select('id, phone, email, full_name')
        .eq('phone', digits)
        .maybeSingle();

    if (byDigits != null) {
      _existingUserId = byDigits['id']?.toString();
      _loginLog('Existing user found by digits. userId=$_existingUserId row=$byDigits');
      return true;
    }

    final byE164 = await client
        .from('users')
        .select('id, phone, email, full_name')
        .eq('phone', e164)
        .maybeSingle();

    if (byE164 != null) {
      _existingUserId = byE164['id']?.toString();
      _loginLog('Existing user found by e164. userId=$_existingUserId row=$byE164');
      return true;
    }

    _existingUserId = null;
    _loginLog('No existing user found for phone=$e164');
    return false;
  }

  bool _isProfileIncomplete(Map<String, dynamic>? row) {
    if (row == null) return true;
    final fullName = (row['full_name'] as String?)?.trim() ?? '';
    final email = (row['email'] as String?)?.trim() ?? '';
    final country = (row['country'] as String?)?.trim() ?? '';
    final state = (row['state'] as String?)?.trim() ?? '';
    return fullName.isEmpty || email.isEmpty || country.isEmpty || state.isEmpty;
  }

  Future<void> _sendAuthEmailConfirmationIfNeeded(
    String? rawEmail, {
    required String reason,
  }) async {
    final email = (rawEmail ?? '').trim().toLowerCase();
    if (email.isEmpty) return;

    final client = Supabase.instance.client;
    final currentUser = client.auth.currentUser;
    if (currentUser == null) {
      _loginLog('[$reason] Skipping email confirmation request: no active auth user');
      return;
    }

    final currentEmail = (currentUser.email ?? '').trim().toLowerCase();
    final isAlreadyVerified = currentUser.emailConfirmedAt != null;
    if (currentEmail == email && isAlreadyVerified) {
      _loginLog('[$reason] Email already linked and verified in auth.users: $email');
      return;
    }

    try {
      await _gatewayPost('/auth/otp/email/confirm-request', {'email': email});
      _loginLog('[$reason] Requested confirmation email via gateway for auth.users email=$email');
      unawaited(_showIslandMessage('te enviamos un correo para confirmar tu email'));
      return;
    } on _GatewayOtpException catch (err) {
      final lower = err.message.toLowerCase();
      final isRateLimited = err.statusCode == 429 || lower.contains('rate limit');
      if (isRateLimited) {
        _loginLog('[$reason] Email confirmation is rate-limited in gateway for $email: ${err.message}');
        unawaited(_showIslandMessage('ya te enviamos un correo recientemente'));
        return;
      }
      _loginLog('[$reason] Gateway email confirmation request failed (will fallback app-side): ${err.message}');
    } catch (err) {
      _loginLog('[$reason] Gateway email confirmation request error (will fallback app-side): $err');
    }

    try {
      await client.auth.updateUser(
        UserAttributes(email: email),
      );
      _loginLog('[$reason] Requested Supabase confirmation email for auth.users email=$email');
      unawaited(_showIslandMessage('te enviamos un correo para confirmar tu email'));
    } catch (err) {
      _loginLog('[$reason] Failed requesting Supabase confirmation email for $email: $err');
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
    if (!mounted) return;
    setState(() => _showIsland = false);
  }

  Future<void> _routeAfterLogin({
    required String userId,
    Map<String, dynamic>? userRow,
  }) async {
    final client = Supabase.instance.client;
    final row = userRow ??
        await client
            .from('users')
            .select('id, phone, email, full_name, country, state')
            .eq('id', userId)
            .maybeSingle();

    await _sendAuthEmailConfirmationIfNeeded(
      (row?['email'] as String?) ?? _emailForOtp,
      reason: 'post-login-route',
    );

    final incomplete = _isProfileIncomplete(row);
    _loginLog('Post-login profile completeness check userId=$userId incomplete=$incomplete row=$row');
    if (!mounted) return;
    if (incomplete) {
      _loginLog('Routing userId=$userId to /kyc?start=profile due to incomplete profile');
      context.go('/kyc?start=profile');
      return;
    }
    _loginLog('Routing userId=$userId to /home (profile complete)');
    context.go('/home');
  }

  Future<void> _sendOtp() async {
    if (_isSendingOtp) return;
    final normalized = _normalizedPhone;
    if (normalized == null || !_isPhoneValid) return;
    setState(() {
      _isSendingOtp = true;
      _errorText = null;
    });

    try {
      final exists = await _phoneExists(normalized);
      if (!exists) {
        setState(() {
          _errorText = 'No encontramos una cuenta con ese número. Toca crear una cuenta.';
        });
        return;
      }

      if (_bypassOtpValidationForDev) {
        _loginLog('BYPASS_OTP=true, skipping login OTP verify and checking profile completeness');
        final userId = Supabase.instance.client.auth.currentUser?.id ?? _existingUserId;
        if (userId == null) {
          if (!mounted) return;
          context.go('/home');
          return;
        }
        final row = await Supabase.instance.client
            .from('users')
            .select('id, phone, email, full_name, country, state')
            .eq('id', userId)
            .maybeSingle();
        if (!mounted) return;
        await _routeAfterLogin(userId: userId, userRow: row);
        return;
      }

      _loginLog('Requesting OTP for existing user phone=$normalized');
      final response = await _sendOtpViaGateway(channel: 'sms', phone: normalized);
      final cooldownSeconds = (response['cooldownSeconds'] as num?)?.toInt() ?? 60;

      _loginLog('OTP requested successfully for phone=$normalized');
      setState(() {
        _phoneE164 = normalized;
        _otpChannel = 'sms';
        _otpController.clear();
        _step = 1;
      });
      _startResendCooldown(cooldownSeconds);
      Future.delayed(const Duration(milliseconds: 120), () {
        if (mounted) FocusScope.of(context).requestFocus(_otpFocusNode);
      });
    } on _GatewayOtpException catch (err) {
      _loginLog('OTP request gateway error: ${err.message} code=${err.code} retry=${err.retryAfterSeconds}');
      setState(() => _errorText = _retryMessage(err.message, err.retryAfterSeconds));
    } on AuthException catch (err) {
      _loginLog('OTP request auth error: ${err.message}');
      setState(() => _errorText = err.message);
    } catch (err) {
      _loginLog('OTP request error: $err');
      setState(() => _errorText = 'No se pudo enviar el código: $err');
    } finally {
      if (mounted) {
        setState(() => _isSendingOtp = false);
      }
    }
  }

  Future<bool> _emailExists(String emailInput) async {
    final client = Supabase.instance.client;
    final normalized = emailInput.trim().toLowerCase();
    _loginLog('Checking existing user by email=$normalized');

    final byEmail = await client
        .from('users')
        .select('id, phone, email, full_name')
        .eq('email', normalized)
        .maybeSingle();

    if (byEmail != null) {
      _existingUserId = byEmail['id']?.toString();
      _loginLog('Existing user found by email. userId=$_existingUserId row=$byEmail');
      return true;
    }

    _existingUserId = null;
    _loginLog('No existing user found for email=$normalized');
    return false;
  }

  Future<void> _sendEmailOtp() async {
    if (_isSendingOtp) return;
    final email = _emailController.text.trim().toLowerCase();
    if (!_isValidEmail(email)) return;

    setState(() {
      _isSendingOtp = true;
      _errorText = null;
    });

    try {
      final exists = await _emailExists(email);
      if (!exists) {
        setState(() {
          _errorText = 'No encontramos una cuenta con ese correo. Toca crear una cuenta.';
        });
        return;
      }

      if (_bypassOtpValidationForDev) {
        _loginLog('BYPASS_OTP=true, skipping login OTP verify (email path) and checking profile completeness');
        final userId = Supabase.instance.client.auth.currentUser?.id ?? _existingUserId;
        if (userId == null) {
          if (!mounted) return;
          context.go('/home');
          return;
        }
        final row = await Supabase.instance.client
            .from('users')
            .select('id, phone, email, full_name, country, state')
            .eq('id', userId)
            .maybeSingle();
        if (!mounted) return;
        await _routeAfterLogin(userId: userId, userRow: row);
        return;
      }

      final response = await _sendOtpViaGateway(channel: 'email', email: email);
      final cooldownSeconds = (response['cooldownSeconds'] as num?)?.toInt() ?? 60;

      setState(() {
        _otpChannel = 'email';
        _emailForOtp = email;
        _otpController.clear();
        _step = 1;
      });
      _startResendCooldown(cooldownSeconds);
      Future.delayed(const Duration(milliseconds: 120), () {
        if (mounted) FocusScope.of(context).requestFocus(_otpFocusNode);
      });
    } on _GatewayOtpException catch (err) {
      _loginLog('Email OTP request gateway error: ${err.message} code=${err.code} retry=${err.retryAfterSeconds}');
      setState(() => _errorText = _retryMessage(err.message, err.retryAfterSeconds));
    } catch (err) {
      _loginLog('Email OTP request error: $err');
      setState(() => _errorText = 'No se pudo enviar el código: $err');
    } finally {
      if (mounted) {
        setState(() => _isSendingOtp = false);
      }
    }
  }

  Future<void> _resendCode() async {
    if (_isSendingOtp || _resendSecondsLeft > 0) return;

    setState(() {
      _isSendingOtp = true;
      _errorText = null;
    });

    try {
      Map<String, dynamic> response;
      if (_otpChannel == 'email') {
        final email = _emailForOtp;
        if (email == null || email.isEmpty) {
          setState(() => _errorText = 'falta el correo electrónico.');
          return;
        }
        response = await _sendOtpViaGateway(channel: 'email', email: email);
      } else {
        final phone = _phoneE164;
        if (phone == null || phone.isEmpty) {
          setState(() => _errorText = 'falta el número de teléfono.');
          return;
        }
        response = await _sendOtpViaGateway(channel: 'sms', phone: phone);
      }

      final cooldownSeconds = (response['cooldownSeconds'] as num?)?.toInt() ?? 60;
      _startResendCooldown(cooldownSeconds);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('código reenviado.')),
      );
    } on _GatewayOtpException catch (err) {
      _loginLog('Resend gateway error: ${err.message} code=${err.code} retry=${err.retryAfterSeconds}');
      setState(() => _errorText = _retryMessage(err.message, err.retryAfterSeconds));
    } catch (err) {
      _loginLog('Resend OTP error: $err');
      setState(() => _errorText = 'No se pudo reenviar: $err');
    } finally {
      if (mounted) {
        setState(() => _isSendingOtp = false);
      }
    }
  }

  Future<void> _verifyOtpAndLogin() async {
    if (_isVerifyingOtp) return;
    final phone = _phoneE164;
    final email = _emailForOtp;
    final token = _otpController.text.trim();
    if ((_otpChannel == 'sms' && (phone == null || phone.isEmpty)) ||
        (_otpChannel == 'email' && (email == null || email.isEmpty)) ||
        token.length != 6) {
      return;
    }

    setState(() {
      _isVerifyingOtp = true;
      _errorText = null;
    });

    try {
      final client = Supabase.instance.client;
      await _checkVerifyLock();
      _loginLog('Verifying OTP. channel=$_otpChannel tokenLength=${token.length} phone=$phone email=$email');
      final result = await client.auth.verifyOTP(
        type: _otpChannel == 'sms' ? OtpType.sms : OtpType.email,
        token: token,
        phone: _otpChannel == 'sms' ? phone : null,
        email: _otpChannel == 'email' ? email : null,
      );
      await _recordVerifyAttempt(true);
      final userId = result.user?.id ?? client.auth.currentUser?.id;
      _loginLog('verifyOTP success. session=${result.session != null} userId=$userId expectedExisting=$_existingUserId');

      if (userId == null) {
        setState(() => _errorText = 'No se creó sesión de usuario.');
        return;
      }

      final existingRow = await client
          .from('users')
          .select('id, phone, email, full_name, country, state')
          .eq('id', userId)
          .maybeSingle();
      _loginLog('public.users row after login verify: $existingRow');

      if (!mounted) return;
        await _routeAfterLogin(userId: userId, userRow: existingRow);
    } on _GatewayOtpException catch (err) {
      _loginLog('verify-lock gateway error: ${err.message} code=${err.code} retry=${err.retryAfterSeconds}');
      setState(() => _errorText = _retryMessage(err.message, err.retryAfterSeconds));
    } on AuthException catch (err) {
      await _recordVerifyAttempt(false);
      _loginLog('verifyOTP auth error: ${err.message}');
      setState(() => _errorText = err.message);
    } catch (err) {
      _loginLog('verifyOTP error: $err');
      setState(() => _errorText = 'No se pudo iniciar sesión: $err');
    } finally {
      if (mounted) {
        setState(() => _isVerifyingOtp = false);
      }
    }
  }

  Widget _buildPhoneStep() {
    final phoneReady = _isPhoneValid && _normalizedPhone != null;
    final showInvalidPhoneHint =
        _phoneController.text.trim().isNotEmpty && !_isPhoneValid && _errorText == null;
    return Column(
      children: [
        const SizedBox(height: 24),
        SizedBox(
          width: 351,
          child: const Text(
            'bienvenido a call a vet.\npor favor introduce tu número de teléfono para iniciar sesión:',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(height: 34),
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
                  CircleAvatar(
                    radius: 12.5,
                    backgroundColor: Color(0xFF2E2E2E),
                    child: Text(_flagEmoji, style: const TextStyle(fontSize: 14)),
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
            const SizedBox(width: 11),
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
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  onChanged: (_) => _schedulePhoneValidation(),
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
                    fontSize: 15,
                    fontFamily: 'ABC Diatype',
                    fontWeight: FontWeight.w400,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: '55 1234 5678',
                    hintStyle: TextStyle(
                      color: Color(0xFF3A3A3A),
                      fontSize: 15,
                      fontFamily: 'ABC Diatype',
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (showInvalidPhoneHint) ...[
          const SizedBox(height: 10),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'introduce un número de teléfono válido.',
              style: TextStyle(
                color: Color(0xFFFF8A80),
                fontSize: 12,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
        if (_errorText != null) ...[
          const SizedBox(height: 12),
          Text(
            _errorText!,
            style: const TextStyle(
              color: Color(0xFFFF8A80),
              fontSize: 12,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
        const Spacer(),
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
                  onPressed: (phoneReady && !_isSendingOtp) ? _sendOtp : null,
                  style: ElevatedButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF101010),
                    disabledBackgroundColor: Colors.white.withOpacity(0.2),
                  ),
                  child: _isSendingOtp
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF101010)),
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
  }

  Widget _buildOtpStep() {
    final canSubmit = _otpController.text.trim().length == 6 && !_isVerifyingOtp;
    final destinationLabel = _otpChannel == 'sms' ? _phoneE164 : _emailForOtp;
    final emailFallbackEnabled = _resendSecondsLeft == 0 && !_isSendingOtp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
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
        if (destinationLabel != null && destinationLabel.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              width: 351,
              child: Text(
                'enviado a $destinationLabel',
                style: const TextStyle(
                  color: Color(0x99FFFFFF),
                  fontSize: 12,
                  fontFamily: 'ABC Diatype',
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ),
        const SizedBox(height: 24),
        SizedBox(
          width: 351,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  _OtpGroupBox(digits: _otpController.text, startIndex: 0),
                  const SizedBox(width: 20),
                  _OtpGroupBox(digits: _otpController.text, startIndex: 3),
                ],
              ),
              Opacity(
                opacity: 0,
                child: TextField(
                  controller: _otpController,
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
        ),
        if (_errorText != null) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _errorText!,
              style: const TextStyle(
                color: Color(0xFFFF8A80),
                fontSize: 12,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: (_resendSecondsLeft == 0 && !_isSendingOtp) ? _resendCode : null,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: Text(
              _isSendingOtp
                  ? 'reenviando...'
                  : _resendSecondsLeft > 0
                      ? 'reenviar código (${_resendSecondsLeft}s)'
                      : 'reenviar código',
              style: TextStyle(
                color: (_resendSecondsLeft == 0 && !_isSendingOtp)
                    ? Colors.white
                    : const Color(0x99FFFFFF),
                fontSize: 12,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: emailFallbackEnabled
                ? () => setState(() {
                      _step = 2;
                      _errorText = null;
                    })
                : null,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: Text(
              'enviarlo por correo electrónico',
              style: TextStyle(
                color: emailFallbackEnabled ? Colors.white : const Color(0x99FFFFFF),
                fontSize: 12,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              const Text(
                'iniciar',
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
                  onPressed: canSubmit ? _verifyOtpAndLogin : null,
                  style: ElevatedButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF101010),
                    disabledBackgroundColor: Colors.white.withOpacity(0.2),
                  ),
                  child: _isVerifyingOtp
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF101010)),
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
  }

  Widget _buildEmailStep() {
    final email = _emailController.text.trim();
    final isEmailValid = _isValidEmail(email);
    final showInvalidEmailHint = _showEmailValidationError && _errorText == null;

    return Column(
      children: [
        const SizedBox(height: 24),
        SizedBox(
          width: 351,
          child: const Text(
            'bienvenido a call a vet.\npor favor introduce tu correo electrónico para iniciar sesión:',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(height: 34),
        Row(
          children: [
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
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  onChanged: (_) {
                    setState(() {});
                    _scheduleEmailValidation();
                  },
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontFamily: 'ABC Diatype',
                    fontWeight: FontWeight.w400,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'correo@dominio.com',
                    hintStyle: TextStyle(
                      color: Color(0xFF3A3A3A),
                      fontSize: 15,
                      fontFamily: 'ABC Diatype',
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (showInvalidEmailHint) ...[
          const SizedBox(height: 10),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'introduce un correo electrónico válido.',
              style: TextStyle(
                color: Color(0xFFFF8A80),
                fontSize: 12,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
        if (_errorText != null) ...[
          const SizedBox(height: 12),
          Text(
            _errorText!,
            style: const TextStyle(
              color: Color(0xFFFF8A80),
              fontSize: 12,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
        const Spacer(),
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
                  onPressed: (isEmailValid && !_isSendingOtp) ? _sendEmailOtp : null,
                  style: ElevatedButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF101010),
                    disabledBackgroundColor: Colors.white.withOpacity(0.2),
                  ),
                  child: _isSendingOtp
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF101010)),
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
  }

  @override
  Widget build(BuildContext context) {
    final headerAction = _step == 0
        ? SizedBox(
            height: 38,
            child: TextButton(
              onPressed: () => context.go('/kyc'),
              style: TextButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(33.5),
                ),
              ),
              child: const Text(
                'crear una cuenta',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 14,
                  fontFamily: 'ABC Diatype',
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          )
        : TextButton(
            onPressed: () {
              final currentStep = _step;
              setState(() {
                _step = currentStep == 2 ? 1 : 0;
                _errorText = null;
                if (currentStep == 1) {
                  _otpController.clear();
                }
              });
            },
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: const Text(
              'volver',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.underline,
              ),
            ),
          );

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
                    children: [
                      const Spacer(),
                      headerAction,
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const SizedBox(width: 8),
                      SvgPicture.asset(
                        'assets/icons/call a vet.svg',
                        width: 118,
                        fit: BoxFit.contain,
                      ),
                    ],
                  ),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, animation) {
                        final slide = Tween<Offset>(
                          begin: const Offset(0.04, 0),
                          end: Offset.zero,
                        ).animate(animation);
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(position: slide, child: child),
                        );
                      },
                      child: KeyedSubtree(
                        key: ValueKey<int>(_step),
                        child: _step == 0
                            ? _buildPhoneStep()
                            : _step == 1
                                ? _buildOtpStep()
                                : _buildEmailStep(),
                      ),
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

class _GatewayOtpException implements Exception {
  const _GatewayOtpException({
    required this.message,
    this.code,
    this.retryAfterSeconds,
    this.statusCode,
  });

  final String message;
  final String? code;
  final int? retryAfterSeconds;
  final int? statusCode;
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
