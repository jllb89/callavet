import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/environment.dart';

class VetDashboardScreen extends StatefulWidget {
  const VetDashboardScreen({super.key});

  @override
  State<VetDashboardScreen> createState() => _VetDashboardScreenState();
}

class _VetDashboardScreenState extends State<VetDashboardScreen> {
  bool _showProfile = false;
  bool _availableNow = true;
  late Future<_VetProfileBundle> _profileBundleFuture;

  @override
  void initState() {
    super.initState();
    _profileBundleFuture = _loadProfileBundle();
  }

  Future<_VetProfileBundle> _loadProfileBundle() async {
    final profileResponse = await _getGatewayJson('/vets/me/profile');
    final specialtiesResponse = await _getGatewayJson('/vets/specialties');
    final queueResponse = await _getGatewayJson('/vets/me/queue');
    final specialties = _asList(specialtiesResponse['data'])
            ?.map(_asMap)
            .whereType<Map<String, dynamic>>()
            .map(_VetSpecialty.fromJson)
            .where((specialty) => specialty.isActive)
            .toList() ??
        const <_VetSpecialty>[];
    return _VetProfileBundle(
      profile: _VetProfile.fromJson(profileResponse),
      specialties: specialties,
      queue: _VetQueue.fromJson(queueResponse),
    );
  }

  Future<Map<String, dynamic>> _getGatewayJson(String path) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      throw const _VetProfileException('Tu sesión expiró. Vuelve a iniciar sesión.');
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(Uri.parse('${Environment.apiBaseUrl}$path'));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close().timeout(const Duration(seconds: 30));
      final rawBody = await utf8.decoder.bind(response).join();
      final decoded = rawBody.trim().isEmpty ? <String, dynamic>{} : jsonDecode(rawBody);
      final data = _asMap(decoded) ?? <String, dynamic>{};
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _VetProfileException(_errorMessage(data, response.statusCode));
      }
      return data;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _patchGatewayJson(String path, Map<String, dynamic> body) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      throw const _VetProfileException('Tu sesión expiró. Vuelve a iniciar sesión.');
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.patchUrl(Uri.parse('${Environment.apiBaseUrl}$path'));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close().timeout(const Duration(seconds: 30));
      final rawBody = await utf8.decoder.bind(response).join();
      final decoded = rawBody.trim().isEmpty ? <String, dynamic>{} : jsonDecode(rawBody);
      final data = _asMap(decoded) ?? <String, dynamic>{};
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _VetProfileException(_errorMessage(data, response.statusCode));
      }
      return data;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _saveProfile(Map<String, dynamic> body) async {
    await _patchGatewayJson('/vets/me/profile', body);
  }

  void _showHome() {
    setState(() => _showProfile = false);
  }

  void _showProfileScreen() {
    setState(() {
      _profileBundleFuture = _loadProfileBundle();
      _showProfile = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final content = _showProfile
        ? Padding(
            padding: const EdgeInsets.only(top: 28),
            child: _ProfilePage(
              profileBundleFuture: _profileBundleFuture,
              onSave: _saveProfile,
              onReload: () => setState(() => _profileBundleFuture = _loadProfileBundle()),
            ),
          )
        : _DashboardPage(
            availableNow: _availableNow,
            profileBundleFuture: _profileBundleFuture,
          );

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
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 24, 32, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_showProfile)
                  _ProfileTopBar(onBack: _showHome)
                else
                  _VetTopBar(
                    availableNow: _availableNow,
                    onHomeTap: _showHome,
                    onProfileTap: _showProfileScreen,
                    onAvailabilityChanged: (value) => setState(() => _availableNow = value),
                  ),
                Expanded(child: content),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileTopBar extends StatelessWidget {
  const _ProfileTopBar({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
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

class _VetTopBar extends StatelessWidget {
  const _VetTopBar({
    required this.availableNow,
    required this.onHomeTap,
    required this.onProfileTap,
    required this.onAvailabilityChanged,
  });

  final bool availableNow;
  final VoidCallback onHomeTap;
  final VoidCallback onProfileTap;
  final ValueChanged<bool> onAvailabilityChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: onProfileTap,
              child: SizedBox(
                width: 34,
                height: 34,
                child: SvgPicture.asset(
                  'assets/icons/user.svg',
                  fit: BoxFit.contain,
                  colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                ),
              ),
            ),
          ),
          GestureDetector(
            onTap: onHomeTap,
            child: SvgPicture.asset(
              'assets/icons/homelogo.svg',
              width: 91,
              height: 18,
              fit: BoxFit.contain,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: _TinyAvailabilitySwitch(
              value: availableNow,
              onChanged: onAvailabilityChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _TinyAvailabilitySwitch extends StatelessWidget {
  const _TinyAvailabilitySwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 48,
        height: 42,
        child: Align(
          alignment: Alignment.centerRight,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            width: 38,
            height: 22,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: value ? Colors.white.withValues(alpha: 0.28) : Colors.white.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: value ? 0.45 : 0.22)),
            ),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 16,
                height: 16,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashboardPage extends StatelessWidget {
  const _DashboardPage({
    required this.availableNow,
    required this.profileBundleFuture,
  });

  final bool availableNow;
  final Future<_VetProfileBundle> profileBundleFuture;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 96),
                    _DashboardGreeting(profileBundleFuture: profileBundleFuture),
                    const SizedBox(height: 6),
                    const SizedBox(
                      width: 332,
                      child: Text(
                        'Esta es tu actividad:',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontFamily: 'ABC Diatype',
                          fontWeight: FontWeight.w400,
                          height: 1.10,
                        ),
                      ),
                    ),
                    const SizedBox(height: 30),
                    const _BoltMark(),
                    const SizedBox(height: 42),
                    _ActivitySections(
                      availableNow: availableNow,
                      profileBundleFuture: profileBundleFuture,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const _VetMessageComposer(),
      ],
    );
  }
}

class _DashboardGreeting extends StatelessWidget {
  const _DashboardGreeting({required this.profileBundleFuture});

  final Future<_VetProfileBundle> profileBundleFuture;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_VetProfileBundle>(
      future: profileBundleFuture,
      builder: (context, snapshot) {
        final firstName = _firstNameFrom(snapshot.data?.profile.fullName);
        return Text(
          firstName == null ? '¡Hola!' : '¡Hola, $firstName!',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontFamily: 'ABC Diatype',
            fontWeight: FontWeight.w400,
          ),
        );
      },
    );
  }
}

class _BoltMark extends StatelessWidget {
  const _BoltMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.bolt, color: Colors.black, size: 18),
    );
  }
}

class _ActivitySections extends StatelessWidget {
  const _ActivitySections({required this.availableNow, required this.profileBundleFuture});

  final bool availableNow;
  final Future<_VetProfileBundle> profileBundleFuture;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_VetProfileBundle>(
      future: profileBundleFuture,
      builder: (context, snapshot) {
        final queue = snapshot.data?.queue;
        final activeConsults = queue?.activeConsults ?? const <_ActiveConsult>[];
        final upcomingAppointments = queue?.upcomingAppointments ?? const <_UpcomingAppointment>[];
        final isLoading = snapshot.connectionState == ConnectionState.waiting;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              availableNow ? 'consultas activas:' : 'fuera de guardia:',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 24),
            if (isLoading)
              const _LoadingTag()
            else if (activeConsults.isEmpty)
              const _EmptyActivityText('No tienes consultas activas.')
            else
              _ActiveConsultPills(consults: activeConsults),
            const SizedBox(height: 46),
            const Text(
              'próximas consultas:',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 28),
            if (isLoading)
              const _LoadingTag()
            else if (upcomingAppointments.isEmpty)
              const _EmptyActivityText('No tienes videollamadas programadas.')
            else
              _UpcomingAppointmentsList(appointments: upcomingAppointments),
          ],
        );
      },
    );
  }
}

class _ActiveConsultPills extends StatelessWidget {
  const _ActiveConsultPills({required this.consults});

  final List<_ActiveConsult> consults;

  @override
  Widget build(BuildContext context) {
    final consult = consults.first;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      child: Row(
        children: [
          _PrimaryConsultPill(name: consult.name),
          const SizedBox(width: 13),
          _DarkTagPill(label: consult.status),
          const SizedBox(width: 13),
          _DarkTagPill(label: consult.mode),
        ],
      ),
    );
  }
}

class _PrimaryConsultPill extends StatelessWidget {
  const _PrimaryConsultPill({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 51,
      padding: const EdgeInsets.only(left: 20, right: 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(40),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.chat_bubble_outline, color: Colors.black, size: 17),
          const SizedBox(width: 12),
          Text(
            name,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 13,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _DarkTagPill extends StatelessWidget {
  const _DarkTagPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(40),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontFamily: 'ABC Diatype',
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _UpcomingAppointmentsList extends StatelessWidget {
  const _UpcomingAppointmentsList({required this.appointments});

  final List<_UpcomingAppointment> appointments;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'hoy:',
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontFamily: 'ABC Diatype',
            fontWeight: FontWeight.w400,
          ),
        ),
        const SizedBox(height: 10),
        ...appointments.take(3).map((appointment) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              child: _UpcomingConsultPill(name: appointment.name, time: appointment.formattedStart),
            ),
          );
        }),
      ],
    );
  }
}

class _UpcomingConsultPill extends StatelessWidget {
  const _UpcomingConsultPill({required this.name, required this.time});

  final String name;
  final String time;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 51,
      padding: const EdgeInsets.only(left: 21, right: 18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(40),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videocam_outlined, color: Colors.white, size: 19),
          const SizedBox(width: 18),
          Text(
            name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w400,
              height: 1.85,
            ),
          ),
          const SizedBox(width: 28),
          Text(
            time,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontFamily: 'ABC Diatype',
              fontWeight: FontWeight.w300,
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingTag extends StatelessWidget {
  const _LoadingTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 92,
      height: 30,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(40),
      ),
    );
  }
}

class _EmptyActivityText extends StatelessWidget {
  const _EmptyActivityText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 10,
        fontFamily: 'ABC Diatype',
        fontWeight: FontWeight.w300,
        height: 2.40,
      ),
    );
  }
}

class _VetMessageComposer extends StatelessWidget {
  const _VetMessageComposer();

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: 1.10,
      child: Container(
        height: 40,
        padding: const EdgeInsets.only(left: 20, right: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(40),
        ),
        child: Row(
          children: [
            Text(
              'escribir mensaje...',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.30),
                fontSize: 13,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            SvgPicture.asset(
              'assets/icons/rightup.svg',
              width: 17,
              height: 17,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfilePage extends StatelessWidget {
  const _ProfilePage({
    required this.profileBundleFuture,
    required this.onSave,
    required this.onReload,
  });

  final Future<_VetProfileBundle> profileBundleFuture;
  final Future<void> Function(Map<String, dynamic> body) onSave;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_VetProfileBundle>(
      future: profileBundleFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: Colors.white));
        }
        if (snapshot.hasError) {
          return _ProfileError(message: snapshot.error.toString(), onReload: onReload);
        }
        final bundle = snapshot.data;
        if (bundle == null) {
          return _ProfileError(message: 'No pude cargar el perfil veterinario.', onReload: onReload);
        }
        return _ProfileEditor(bundle: bundle, onSave: onSave);
      },
    );
  }
}

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor({required this.bundle, required this.onSave});

  final _VetProfileBundle bundle;
  final Future<void> Function(Map<String, dynamic> body) onSave;

  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  late final TextEditingController _bioController;
  late Set<String> _selectedSpecialtyIds;
  bool _saving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    final profile = widget.bundle.profile;
    _bioController = TextEditingController(text: profile.bio);
    _selectedSpecialtyIds = profile.specialtyIds.toSet();
  }

  @override
  void dispose() {
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _message = null;
    });

    try {
      await widget.onSave({
        'bio': _bioController.text.trim(),
        'specialties': _selectedSpecialtyIds.toList(),
      });
      if (!mounted) return;
      setState(() => _message = 'Perfil actualizado.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = 'No pude guardar: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editField(
    TextEditingController controller,
    String label, {
    int maxLines = 1,
    TextInputType? keyboardType,
  }) async {
    final draftController = TextEditingController(text: controller.text);
    final nextValue = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101010),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        final bottomInset = MediaQuery.of(context).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(24, 22, 24, 24 + bottomInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontFamily: 'ABC Diatype',
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: draftController,
                autofocus: true,
                maxLines: maxLines,
                keyboardType: keyboardType,
                cursorColor: Colors.white,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontFamily: 'ABC Diatype',
                  fontWeight: FontWeight.w400,
                ),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: 'tocar para añadir',
                  hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.28),
                    fontSize: 18,
                    fontFamily: 'ABC Diatype',
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: _OnboardingStyleAction(
                  label: 'listo',
                  onPressed: () => Navigator.of(context).pop(draftController.text),
                ),
              ),
            ],
          ),
        );
      },
    );
    draftController.dispose();
    if (nextValue == null) return;
    setState(() => controller.text = nextValue.trim());
  }

  void _toggleSpecialty(String id) {
    setState(() {
      if (_selectedSpecialtyIds.contains(id)) {
        _selectedSpecialtyIds.remove(id);
      } else {
        _selectedSpecialtyIds.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.bundle.profile;
    final metadata = [
      profile.email,
      profile.phone,
      profile.licenseNumber,
      if (profile.ratingCount > 0) '${profile.ratingAverage.toStringAsFixed(1)} (${profile.ratingCount})',
    ].where((value) => value.trim().isNotEmpty).toList();
    return ListView(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Perfil veterinario',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontFamily: 'ABC Diatype',
                      fontWeight: FontWeight.w400,
                      height: 1.02,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    profile.fullName.isEmpty ? 'Veterinario Call a Vet' : profile.fullName,
                    style: TextStyle(
                      color: Colors.white.withAlpha(180),
                      fontSize: 13,
                      fontFamily: 'ABC Diatype',
                    ),
                  ),
                ],
              ),
            ),
            _ApprovalBadge(isApproved: profile.isApproved),
          ],
        ),
        const SizedBox(height: 18),
        ...metadata.map((value) => _ProfileMetaText(value)),
        const SizedBox(height: 20),
        _EditableProfileLine(
          label: 'Bio profesional',
          value: _bioController.text,
          maxLines: 4,
          onTap: () => _editField(_bioController, 'Bio profesional', maxLines: 5),
        ),
        const SizedBox(height: 10),
        const Text(
          'Especialidades',
          style: TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'ABC Diatype', fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: widget.bundle.specialties.map((specialty) {
            final selected = _selectedSpecialtyIds.contains(specialty.id);
            return _SpecialtyToggleTag(
              label: specialty.name,
              selected: selected,
              onTap: () => _toggleSpecialty(specialty.id),
            );
          }).toList(),
        ),
        if (_message != null) ...[
          const SizedBox(height: 12),
          Text(
            _message!,
            style: TextStyle(
              color: _message!.startsWith('No pude') ? const Color(0xFFFF8A80) : Colors.white.withAlpha(190),
              fontSize: 12,
              fontFamily: 'ABCDiatype',
            ),
          ),
        ],
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerRight,
          child: _OnboardingStyleAction(
            label: 'guardar cambios',
            busy: _saving,
            onPressed: _saving ? null : _save,
          ),
        ),
      ],
    );
  }
}

class _EditableProfileLine extends StatelessWidget {
  const _EditableProfileLine({
    required this.label,
    required this.value,
    required this.onTap,
    this.maxLines = 1,
  });

  final String label;
  final String value;
  final VoidCallback onTap;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final trimmed = value.trim();
    final hasValue = trimmed.isNotEmpty;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.46),
                fontSize: 11,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              hasValue ? trimmed : 'tocar para añadir',
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: hasValue ? 1 : 0.30),
                fontSize: 16,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w400,
                height: 1.25,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileMetaText extends StatelessWidget {
  const _ProfileMetaText(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        value,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.64),
          fontSize: 12,
          fontFamily: 'ABC Diatype',
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }
}

class _SpecialtyToggleTag extends StatelessWidget {
  const _SpecialtyToggleTag({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 36,
        padding: const EdgeInsets.only(left: 18, right: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? Colors.black : Colors.white,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.black,
                fontSize: 14,
                fontFamily: 'ABC Diatype',
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 9),
            SizedBox(
              width: 18,
              height: 18,
              child: Icon(
                selected ? Icons.close_rounded : Icons.add_rounded,
                color: selected ? Colors.white : Colors.black,
                size: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnboardingStyleAction extends StatelessWidget {
  const _OnboardingStyleAction({required this.label, required this.onPressed, this.busy = false});

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return GestureDetector(
      onTap: enabled ? onPressed : null,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: enabled || busy ? 1 : 0.35,
        child: SizedBox(
          height: 45,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
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
              const SizedBox(width: 8),
              busy
                  ? const SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        ),
                      ),
                    )
                  : SvgPicture.asset(
                      'assets/icons/continue.svg',
                      width: 48,
                      height: 48,
                      colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ApprovalBadge extends StatelessWidget {
  const _ApprovalBadge({required this.isApproved});

  final bool isApproved;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isApproved ? const Color(0x3329D391) : const Color(0x33FFB4AB),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: isApproved ? const Color(0xAA29D391) : const Color(0xAAFFB4AB)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          isApproved ? 'aprobado' : 'pendiente',
          style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'ABCDiatype', fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}

class _ProfileError extends StatelessWidget {
  const _ProfileError({required this.message, required this.onReload});

  final String message;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.badge_outlined, size: 42, color: Colors.white),
            const SizedBox(height: 14),
            const Text('Perfil veterinario', style: TextStyle(color: Colors.white, fontSize: 24, fontFamily: 'ABCDiatype')),
            const SizedBox(height: 8),
            Text(message, style: TextStyle(color: Colors.white.withAlpha(175), fontSize: 13, fontFamily: 'ABCDiatype'), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            TextButton(onPressed: onReload, child: const Text('reintentar', style: TextStyle(color: Colors.white))),
          ],
        ),
      ),
    );
  }
}

class _VetProfileBundle {
  const _VetProfileBundle({required this.profile, required this.specialties, required this.queue});

  final _VetProfile profile;
  final List<_VetSpecialty> specialties;
  final _VetQueue queue;
}

class _VetQueue {
  const _VetQueue({required this.activeConsults, required this.upcomingAppointments});

  factory _VetQueue.fromJson(Map<String, dynamic> json) {
    return _VetQueue(
      activeConsults: _asList(json['activeConsults'])
              ?.map(_asMap)
              .whereType<Map<String, dynamic>>()
              .map(_ActiveConsult.fromJson)
              .toList() ??
          const <_ActiveConsult>[],
      upcomingAppointments: _asList(json['upcomingAppointments'])
              ?.map(_asMap)
              .whereType<Map<String, dynamic>>()
              .map(_UpcomingAppointment.fromJson)
              .toList() ??
          const <_UpcomingAppointment>[],
    );
  }

  final List<_ActiveConsult> activeConsults;
  final List<_UpcomingAppointment> upcomingAppointments;
}

class _ActiveConsult {
  const _ActiveConsult({required this.name, required this.status, required this.mode});

  factory _ActiveConsult.fromJson(Map<String, dynamic> json) {
    final source = json['source']?.toString() ?? '';
    return _ActiveConsult(
      name: _displayName(json),
      status: json['status']?.toString() ?? 'activa',
      mode: source == 'session' ? 'chat' : 'video',
    );
  }

  final String name;
  final String status;
  final String mode;
}

class _UpcomingAppointment {
  const _UpcomingAppointment({required this.name, required this.startsAt});

  factory _UpcomingAppointment.fromJson(Map<String, dynamic> json) {
    return _UpcomingAppointment(
      name: _displayName(json),
      startsAt: _parseDateTime(json['starts_at']),
    );
  }

  final String name;
  final DateTime? startsAt;

  String get formattedStart => startsAt == null ? 'hora por confirmar' : _formatAppointmentDate(startsAt!);
}

class _VetProfile {
  const _VetProfile({
    required this.fullName,
    required this.email,
    required this.phone,
    required this.licenseNumber,
    required this.country,
    required this.bio,
    required this.yearsExperience,
    required this.isApproved,
    required this.languages,
    required this.specialtyIds,
    required this.ratingAverage,
    required this.ratingCount,
  });

  factory _VetProfile.fromJson(Map<String, dynamic> json) {
    return _VetProfile(
      fullName: json['full_name']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      phone: json['phone']?.toString() ?? '',
      licenseNumber: json['license_number']?.toString() ?? '',
      country: json['country']?.toString() ?? '',
      bio: json['bio']?.toString() ?? '',
      yearsExperience: _toInt(json['years_experience']),
      isApproved: json['is_approved'] == true,
      languages: _asList(json['languages'])?.map((value) => value.toString()).toList() ?? const <String>[],
      specialtyIds: _asList(json['specialties'])?.map((value) => value.toString()).toList() ?? const <String>[],
      ratingAverage: _toDouble(json['rating_average']) ?? 0,
      ratingCount: _toInt(json['rating_count']) ?? 0,
    );
  }

  final String fullName;
  final String email;
  final String phone;
  final String licenseNumber;
  final String country;
  final String bio;
  final int? yearsExperience;
  final bool isApproved;
  final List<String> languages;
  final List<String> specialtyIds;
  final double ratingAverage;
  final int ratingCount;
}

class _VetSpecialty {
  const _VetSpecialty({required this.id, required this.name, required this.isActive});

  factory _VetSpecialty.fromJson(Map<String, dynamic> json) {
    return _VetSpecialty(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      isActive: json['is_active'] != false,
    );
  }

  final String id;
  final String name;
  final bool isActive;
}

class _VetProfileException implements Exception {
  const _VetProfileException(this.message);

  final String message;

  @override
  String toString() => message;
}

Map<String, dynamic>? _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((key, entry) => MapEntry(key.toString(), entry));
  return null;
}

List<dynamic>? _asList(Object? value) => value is List ? value : null;

int? _toInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

double? _toDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

String? _firstNameFrom(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed.split(RegExp(r'\s+')).first;
}

String _displayName(Map<String, dynamic> json) {
  final petName = json['pet_name']?.toString().trim();
  if (petName != null && petName.isNotEmpty) return petName;
  final userName = json['user_name']?.toString().trim();
  if (userName != null && userName.isNotEmpty) return userName;
  return 'consulta';
}

DateTime? _parseDateTime(Object? value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString())?.toLocal();
}

String _formatAppointmentDate(DateTime value) {
  final day = value.day.toString().padLeft(2, '0');
  final month = value.month.toString().padLeft(2, '0');
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$day/$month/${value.year}  $hour:${minute}hrs';
}

String _errorMessage(Map<String, dynamic> data, int statusCode) {
  final message = data['message']?.toString();
  if (message != null && message.isNotEmpty) return message;
  final reason = data['reason']?.toString();
  if (reason != null && reason.isNotEmpty) return reason;
  return 'Error del servidor ($statusCode).';
}
