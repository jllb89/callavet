import 'dart:async';

import 'package:country_picker/country_picker.dart';
import 'package:country_picker/src/country_list_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_libphonenumber/flutter_libphonenumber.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class KycScreen extends StatefulWidget {
  const KycScreen({super.key});

  @override
  State<KycScreen> createState() => _KycScreenState();
}

class _KycScreenState extends State<KycScreen> {
  final _pageController = PageController();
  final _phoneController = TextEditingController();
  int _pageIndex = 0;
  String? _e164Phone;
  bool _isSendingOtp = false;
  bool _showIsland = false;
  String _islandText = '';
  double _islandOpacity = 0;

  @override
  void dispose() {
    _pageController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _goNext() {
    final nextPage = _pageIndex + 1;
    if (nextPage < 5) {
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
    setState(() {
      _isSendingOtp = true;
      _e164Phone = e164Phone;
    });
    try {
      final client = Supabase.instance.client;
      await client.auth.signInWithOtp(phone: e164Phone);
      _goNext();
    } on AuthException catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo enviar el código: ${err.message}')),
      );
    } catch (err) {
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
                        _KycOtpScreen(
                          phoneE164: _e164Phone,
                          isActive: _pageIndex == 1,
                          onVerified: () {
                            unawaited(_handleOtpVerified());
                          },
                        ),
                        _KycPlaceholderScreen(
                          title: 'tus datos',
                          description: 'nombre, correo y ubicación.',
                          onNext: _goNext,
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
      await client.auth.verifyOTP(
        type: OtpType.sms,
        token: code,
        phone: phone,
      );
      widget.onVerified();
    } on AuthException catch (err) {
      setState(() => _errorText = err.message);
    } catch (err) {
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
    setState(() {
      _isResending = true;
      _errorText = null;
    });
    try {
      final client = Supabase.instance.client;
      await client.auth.signInWithOtp(phone: phone);
      if (!mounted) return;
      _startResendCooldown();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('código reenviado.')),
      );
    } on AuthException catch (err) {
      setState(() => _errorText = err.message);
    } catch (err) {
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
