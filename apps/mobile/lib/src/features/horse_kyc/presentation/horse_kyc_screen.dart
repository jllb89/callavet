import 'dart:convert';
import 'dart:io';

import 'package:cav_mobile/src/core/config/environment.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void _horseKycLog(String message) {
  debugPrint('[HorseKYC][Flow] $message');
}

const int _kMaxHorseKycImageBytes = 15 * 1024 * 1024;
const int _kMaxHorseKycVideoBytes = 150 * 1024 * 1024;
const double _kHorseBadgeCircleSize = 59;
const double _kHorseBadgeIconSize = 18;

class HorseKycScreen extends StatefulWidget {
  const HorseKycScreen({super.key});

  @override
  State<HorseKycScreen> createState() => _HorseKycScreenState();
}

class _HorseKycScreenState extends State<HorseKycScreen> {
  bool _isLoading = true;
  bool _isSaving = false;
  String? _error;

  List<Map<String, dynamic>> _pets = const [];
  int? _petsIncludedLimit;
  String _defaultCountry = 'MX';
  String _defaultState = 'Jalisco';

  bool get _canContinue => _pets.isNotEmpty;

  bool get _canAddMoreHorses {
    if (_petsIncludedLimit == null) return true;
    return _pets.length < _petsIncludedLimit!;
  }

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    _horseKycLog('Initializing horse KYC screen...');
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await _resolveOwnerLocationDefaults();
      await Future.wait([
        _loadSubscriptionCapacity(),
        _loadPets(),
      ]);
      _horseKycLog('Initial load complete. petsIncludedLimit=$_petsIncludedLimit petsLoaded=${_pets.length}');
    } catch (err) {
      _horseKycLog('Initial load failed: $err');
      _error = 'No se pudo cargar la información: $err';
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _resolveOwnerLocationDefaults() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      _horseKycLog('No user session for location defaults; using fallback');
      return;
    }
    try {
      final row = await Supabase.instance.client
          .from('users')
          .select('country,state')
          .eq('id', userId)
          .maybeSingle();
      final country = (row?['country'] as String?)?.trim();
      final state = (row?['state'] as String?)?.trim();
      if (country != null && country.isNotEmpty) {
        _defaultCountry = country;
      }
      if (state != null && state.isNotEmpty) {
        _defaultState = state;
      }
      _horseKycLog('Owner location defaults resolved: country=$_defaultCountry state=$_defaultState');
    } catch (err) {
      _horseKycLog('Location defaults lookup failed: $err; using fallback');
    }
  }

  Future<void> _loadSubscriptionCapacity() async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      _horseKycLog('No auth token for subscription capacity check');
      _petsIncludedLimit = null;
      return;
    }

    try {
      final response = await _request(
        method: 'GET',
        path: '/subscriptions/my',
        token: token,
      );
      final data = response is Map<String, dynamic> ? response['data'] : null;
      if (data is! List) {
        _horseKycLog('Invalid subscription data format: $data');
        _petsIncludedLimit = null;
        return;
      }

    final active = data.whereType<Map>().map((r) => Map<String, dynamic>.from(r)).firstWhere(
          (row) {
            final status = (row['status']?.toString() ?? '').toLowerCase();
            return status == 'active' || status == 'trialing';
          },
          orElse: () => <String, dynamic>{},
        );

    if (active.isEmpty) {
      _petsIncludedLimit = null;
      return;
    }

      final explicitIncluded = _toInt(active['pets_included']);
      final plan = active['plan'];
      final defaultIncluded = plan is Map ? _toInt(plan['pets_included_default']) : null;
      _petsIncludedLimit = explicitIncluded ?? defaultIncluded;
      _horseKycLog('Subscription capacity loaded: limit=$_petsIncludedLimit explicit=$explicitIncluded default=$defaultIncluded');
    } catch (err) {
      _horseKycLog('Subscription capacity load failed: $err');
      _petsIncludedLimit = null;
    }
  }

  Future<void> _loadPets() async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      _horseKycLog('No auth token for pets load');
      _pets = const [];
      return;
    }

    try {
      final response = await _request(
        method: 'GET',
        path: '/pets',
        token: token,
      );
      final data = response is Map<String, dynamic> ? response['data'] : null;
      if (data is! List) {
        _horseKycLog('Invalid pets data format: $data');
        _pets = const [];
        return;
      }

      _pets = data
          .whereType<Map>()
          .map((raw) => Map<String, dynamic>.from(raw))
          .toList(growable: false);
      _horseKycLog('Pets loaded: count=${_pets.length}');
    } catch (err) {
      _horseKycLog('Pets load failed: $err');
      _pets = const [];
    }
  }

  Future<void> _onAddHorse() async {
    if (_isSaving) return;
    if (!_canAddMoreHorses) {
      final limit = _petsIncludedLimit ?? 0;
      _horseKycLog('Cannot add more horses: limit=$limit current=${_pets.length}');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Tu plan permite hasta $limit caballo(s).'),
        ),
      );
      return;
    }
    _horseKycLog('Add horse triggered: canAddMore=$_canAddMoreHorses');

    final draft = await showModalBottomSheet<_HorseDraft>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _HorseEditorSheet(
        title: 'completa la siguiente información:',
        draft: _HorseDraft.empty(),
      ),
    );
    if (draft == null) return;

    await _saveHorse(draft);
  }

  Future<void> _onEditHorse(Map<String, dynamic> pet) async {
    if (_isSaving) return;
    final petId = pet['id']?.toString() ?? '?';
    final petName = pet['name']?.toString() ?? 'unnamed';
    _horseKycLog('Edit horse triggered: petId=$petId name=$petName');

    final draft = await showModalBottomSheet<_HorseDraft>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _HorseEditorSheet(
        title: 'editar caballo',
        draft: _HorseDraft.fromPet(pet),
      ),
    );
    if (draft == null) return;

    await _saveHorse(draft, petId: pet['id']?.toString());
  }

  Future<void> _saveHorse(
    _HorseDraft draft, {
    String? petId,
  }) async {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) {
      _horseKycLog('Save horse blocked: no auth token');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay sesión activa.')),
      );
      return;
    }

    final isCreate = petId == null || petId.isEmpty;
    _horseKycLog('Save horse started: name=${draft.name} isCreate=$isCreate petId=$petId');
    
    if (isCreate && !_canAddMoreHorses) {
      final limit = _petsIncludedLimit ?? 0;
      _horseKycLog('Save horse blocked: capacity exceeded limit=$limit');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Tu plan permite hasta $limit caballo(s).')),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final payload = draft.toApiPayload(
        defaultCountry: _defaultCountry,
        defaultState: _defaultState,
      );
      String? savedPetId = petId;

      if (isCreate) {
        _horseKycLog('Creating horse via POST /pets: ${draft.name}');
        final created = await _request(
          method: 'POST',
          path: '/pets',
          token: token,
          body: payload,
        );
        if (created is Map<String, dynamic>) {
          savedPetId = created['id']?.toString();
          _horseKycLog('Horse created successfully: petId=$savedPetId');
        }
      } else {
        _horseKycLog('Updating horse via PATCH /pets/$petId: ${draft.name}');
        final updated = await _request(
          method: 'PATCH',
          path: '/pets/$petId',
          token: token,
          body: payload,
        );
        if (updated is Map<String, dynamic>) {
          savedPetId = updated['id']?.toString() ?? petId;
          _horseKycLog('Horse updated successfully: petId=$savedPetId');
        }
      }

      if (savedPetId != null && savedPetId.isNotEmpty && draft.pendingMedia.isNotEmpty) {
        _horseKycLog('Starting media upload for petId=$savedPetId mediaCount=${draft.pendingMedia.length}');
        await _uploadMediaForPet(
          petId: savedPetId,
          token: token,
          media: draft.pendingMedia,
        );
      }

      await _loadPets();
      if (mounted) {
        setState(() {});
        final msg = isCreate ? 'Caballo agregado.' : 'Caballo actualizado.';
        _horseKycLog('Save horse completed: message=$msg');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      }
    } catch (err) {
      _horseKycLog('Save horse failed: $err');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo guardar el caballo: $err')),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _uploadMediaForPet({
    required String petId,
    required String token,
    required List<_PendingMedia> media,
  }) async {
    int uploaded = 0;
    for (var i = 0; i < media.length; i++) {
      final item = media[i];
      final ext = _fileExtension(
        item.file.name,
        fallback: item.kind == _PendingMediaKind.video ? '.mp4' : '.jpg',
      );
      final path = 'pets/$petId/mobile-${DateTime.now().millisecondsSinceEpoch}-$i$ext';
      _horseKycLog('Uploading media [$i/${media.length}]: file=${item.file.name} path=$path contentType=${item.contentType}');

      try {
        final signed = await _request(
          method: 'POST',
          path: '/pets/$petId/files/signed-url',
          token: token,
          body: {
            'path': path,
            'contentType': item.contentType,
          },
        );

        if (signed is! Map<String, dynamic>) {
          throw Exception('signed_url_invalid_response');
        }
        final url = signed['url']?.toString();
        if (url == null || url.isEmpty) {
          throw Exception('signed_url_missing');
        }
        _horseKycLog('Signed URL obtained for media [$i]: uploading to S3...');

        final bytes = await item.file.readAsBytes();
        final putClient = HttpClient();
        try {
          final req = await putClient.putUrl(Uri.parse(url));
          req.headers.set(HttpHeaders.contentTypeHeader, item.contentType);
          req.add(bytes);
          final res = await req.close();
          final raw = await utf8.decoder.bind(res).join();
          if (res.statusCode < 200 || res.statusCode >= 300) {
            throw Exception('upload_failed_${res.statusCode}: $raw');
          }
          uploaded += 1;
          _horseKycLog('Media uploaded successfully [$i]: statusCode=${res.statusCode}');
        } finally {
          putClient.close(force: true);
        }
      } catch (err) {
        _horseKycLog('Media upload failed [$i]: $err');
        rethrow;
      }
    }

    if (!mounted) return;
    _horseKycLog('All media uploads complete: $uploaded/${media.length} uploaded');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Se subieron $uploaded archivo(s).')),
    );
  }

  String _fileExtension(String name, {required String fallback}) {
    final trimmed = name.trim();
    final dot = trimmed.lastIndexOf('.');
    if (dot == -1 || dot == trimmed.length - 1) return fallback;
    return trimmed.substring(dot).toLowerCase();
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
        'PATCH' => await http.patchUrl(uri),
        _ => await http.getUrl(uri),
      };
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.add(utf8.encode(jsonEncode(body)));
      }

      final res = await req.close();
      final raw = await utf8.decoder.bind(res).join();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('gateway_request_failed_${res.statusCode}: $raw');
      }
      if (raw.isEmpty) return null;
      return jsonDecode(raw);
    } finally {
      http.close(force: true);
    }
  }

  int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(0.50, -0.00),
                end: Alignment(0.50, 1.00),
                colors: [Color(0xFF141417), Color(0xFF070707)],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 30),
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: Colors.white))
                  : _error != null
                      ? _ErrorCard(
                          message: _error!,
                          onRetry: _loadInitial,
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Align(
                              alignment: Alignment.topRight,
                              child: TextButton(
                                onPressed: _canContinue ? () => context.go('/home') : null,
                                child: Text(
                                  'saltar',
                                  style: TextStyle(
                                    color: _canContinue ? Colors.white : Colors.white.withValues(alpha: 0.45),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'cuéntanos de tus caballos.',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w500,
                                fontFamily: 'ABC Diatype',
                              ),
                            ),
                            const SizedBox(height: 28),
                            const Text(
                              'agrega tus caballos al plan:',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w500,
                                fontFamily: 'ABC Diatype',
                              ),
                            ),
                            if (_petsIncludedLimit != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                'Cupo del plan: ${_pets.length}/${_petsIncludedLimit!}',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ],
                            const SizedBox(height: 20),
                            Wrap(
                              spacing: 18,
                              runSpacing: 14,
                              children: [
                                ..._pets.map((pet) => _HorseBadge(
                                      name: (pet['name']?.toString() ?? '').trim(),
                                      onTap: () => _onEditHorse(pet),
                                    )),
                                _AddHorseBadge(
                                  enabled: _canAddMoreHorses,
                                  onTap: _onAddHorse,
                                ),
                              ],
                            ),
                            const Spacer(),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Text(
                                  'continuar',
                                  style: TextStyle(
                                    color: _canContinue
                                        ? Colors.white
                                        : Colors.white.withValues(alpha: 0.45),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                GestureDetector(
                                  onTap: _canContinue && !_isSaving
                                      ? () => context.go('/home')
                                      : null,
                                  child: Container(
                                    width: 45,
                                    height: 45,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: _canContinue
                                          ? Colors.white
                                          : Colors.white.withValues(alpha: 0.35),
                                    ),
                                    child: const Icon(
                                      Icons.arrow_forward,
                                      color: Colors.black,
                                      size: 20,
                                    ),
                                  ),
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

class _HorseBadge extends StatelessWidget {
  const _HorseBadge({
    required this.name,
    required this.onTap,
  });

  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = name.isEmpty ? 'caballo' : name;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: _kHorseBadgeCircleSize,
            height: _kHorseBadgeCircleSize,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF23252F),
            ),
            child: Center(
              child: SizedBox(
                width: _kHorseBadgeIconSize,
                height: _kHorseBadgeIconSize,
                child: SvgPicture.asset(
                  'assets/icons/caballo.svg',
                  fit: BoxFit.contain,
                  colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 59,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddHorseBadge extends StatelessWidget {
  const _AddHorseBadge({
    required this.enabled,
    required this.onTap,
  });

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: _kHorseBadgeCircleSize,
            height: _kHorseBadgeCircleSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: enabled ? Colors.white : const Color(0xFF8A8D97),
            ),
            child: Icon(
              Icons.add_circle_outline,
              color: enabled ? Colors.black : const Color(0xFF4A4D58),
              size: 24,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 59,
            child: Text(
              enabled ? 'agregar\ncaballo' : 'limite\nalcanzado',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: enabled ? 1 : 0.65),
                fontSize: 13,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.36),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Hubo un problema',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: onRetry,
              child: const Text('reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}

class _HorseEditorSheet extends StatefulWidget {
  const _HorseEditorSheet({
    required this.title,
    required this.draft,
  });

  final String title;
  final _HorseDraft draft;

  @override
  State<_HorseEditorSheet> createState() => _HorseEditorSheetState();
}

class _HorseEditorSheetState extends State<_HorseEditorSheet> {
  late _HorseDraft _draft;
  final _picker = ImagePicker();
  final _nameCtrl = TextEditingController();
  final _treatmentsCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  int _step = 0;

  @override
  void initState() {
    super.initState();
    _draft = widget.draft.copy();
    _nameCtrl.text = _draft.name;
    _treatmentsCtrl.text = _draft.currentTreatments;
    _notesCtrl.text = _draft.additionalNotes;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _treatmentsCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  bool get _isLastStep => _step == 4;

  bool _isNextEnabled() {
    switch (_step) {
      case 0:
        return _nameCtrl.text.trim().isNotEmpty &&
            _draft.sex != null &&
            _draft.ageRange != null &&
            _draft.weightRange != null &&
            _draft.isInsured != null;
      case 1:
        return _draft.breed != null &&
            (_draft.breed != 'warmblood' || _draft.warmbloodSubbreed != null) &&
            _draft.primaryActivities.isNotEmpty &&
            _draft.trainingIntensity != null &&
            _draft.terrains.isNotEmpty;
      case 2:
        return _draft.observedLastSixMonths.isNotEmpty &&
            _draft.knownConditions.isNotEmpty;
      case 3:
        return _draft.lastVetCheck != null &&
            _draft.vaccinesUpToDate != null &&
            _draft.dewormingStatus != null;
      case 4:
        return _draft.acceptsDisclaimer;
      default:
        return false;
    }
  }

  void _goNext() {
    if (!_isNextEnabled()) {
      return;
    }

    if (_isLastStep) {
      _draft
        ..name = _nameCtrl.text.trim()
        ..currentTreatments = _treatmentsCtrl.text.trim()
        ..additionalNotes = _notesCtrl.text.trim();
      Navigator.of(context).pop(_draft);
      return;
    }

    setState(() => _step += 1);
  }

  void _goBack() {
    if (_step == 0) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _step -= 1);
  }

  Future<void> _pickMedia() async {
    try {
      _horseKycLog('Media picker opened');
      final items = await _picker.pickMultipleMedia();
      if (items.isEmpty) {
        _horseKycLog('Media picker cancelled');
        return;
      }
      _horseKycLog('Media selected: count=${items.length}');
      final accepted = <_PendingMedia>[];
      final rejected = <String>[];
      for (final f in items) {
        final kind = _inferMediaKind(f);
        if (kind == null) {
          rejected.add(f.name);
          continue;
        }

        final maxBytes = _maxBytesFor(kind);
        final sizeBytes = await f.length();
        if (sizeBytes > maxBytes) {
          rejected.add('${f.name} (${_formatBytes(sizeBytes)})');
          continue;
        }

        accepted.add(
          _PendingMedia(
            file: f,
            kind: kind,
            contentType: _inferContentType(f.name, kind),
          ),
        );
      }

      if (accepted.isNotEmpty) {
        setState(() => _draft.pendingMedia.addAll(accepted));
      }
      _horseKycLog('Pending media updated: total=${_draft.pendingMedia.length}');

      if (rejected.isNotEmpty && mounted) {
        final summary = rejected.length == 1
            ? 'No se agregó ${rejected.first}. Máximo: fotos ${_formatBytes(_kMaxHorseKycImageBytes)}, videos ${_formatBytes(_kMaxHorseKycVideoBytes)}.'
            : 'No se agregaron ${rejected.length} archivos. Máximo: fotos ${_formatBytes(_kMaxHorseKycImageBytes)}, videos ${_formatBytes(_kMaxHorseKycVideoBytes)}.';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(summary)));
      }
    } catch (err) {
      _horseKycLog('Media picker error: $err');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo seleccionar media: $err')),
      );
    }
  }

  _PendingMediaKind? _inferMediaKind(XFile file) {
    final mime = file.mimeType?.toLowerCase();
    if (mime != null && mime.startsWith('video/')) return _PendingMediaKind.video;
    if (mime != null && mime.startsWith('image/')) return _PendingMediaKind.image;

    final name = file.name.toLowerCase();
    final path = file.path.toLowerCase();
    const videoExts = ['.mp4', '.mov', '.m4v', '.webm', '.avi'];
    const imageExts = ['.jpg', '.jpeg', '.png', '.webp', '.heic', '.heif'];
    if (videoExts.any((ext) => name.endsWith(ext) || path.endsWith(ext))) {
      return _PendingMediaKind.video;
    }
    if (imageExts.any((ext) => name.endsWith(ext) || path.endsWith(ext))) {
      return _PendingMediaKind.image;
    }
    return null;
  }

  int _maxBytesFor(_PendingMediaKind kind) {
    return kind == _PendingMediaKind.video
        ? _kMaxHorseKycVideoBytes
        : _kMaxHorseKycImageBytes;
  }

  String _formatBytes(int bytes) {
    final mb = bytes / (1024 * 1024);
    if (mb >= 10) return '${mb.round()} MB';
    return '${mb.toStringAsFixed(1)} MB';
  }

  String _inferContentType(String fileName, _PendingMediaKind kind) {
    final lower = fileName.toLowerCase();
    if (kind == _PendingMediaKind.image) {
      if (lower.endsWith('.heic')) return 'image/heic';
      if (lower.endsWith('.heif')) return 'image/heif';
      if (lower.endsWith('.png')) return 'image/png';
      if (lower.endsWith('.webp')) return 'image/webp';
      return 'image/jpeg';
    }
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.m4v')) return 'video/x-m4v';
    if (lower.endsWith('.webm')) return 'video/webm';
    return 'video/mp4';
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: viewInsets.bottom),
        child: Container(
          height: MediaQuery.of(context).size.height * 0.9,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(0.50, -0.00),
              end: Alignment(0.50, 1.00),
              colors: [Color(0xFF141417), Color(0xFF070707)],
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(34)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 16, 18, 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: SvgPicture.asset(
                        'assets/icons/x-circle 1.svg',
                        width: 22,
                        height: 22,
                        colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: KeyedSubtree(
                      key: ValueKey(_step),
                      child: _buildStepContent(),
                    ),
                  ),
                ),
              ),
              if (_isLastStep) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 2, 28, 16),
                  child: Column(
                    children: [
                      _CompactCheckbox(
                        value: _draft.allowPreventiveSuggestions,
                        label: 'Autorizo el uso de esta información para sugerencias de cuidado preventivo.',
                        onChanged: (v) => setState(() => _draft.allowPreventiveSuggestions = v),
                      ),
                      const SizedBox(height: 10),
                      _CompactCheckbox(
                        value: _draft.acceptsDisclaimer,
                        label: 'Entiendo que Call a Vet no reemplaza una revisión presencial',
                        onChanged: (v) => setState(() => _draft.acceptsDisclaimer = v),
                      ),
                    ],
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 22),
                child: Row(
                  children: [
                    if (_step > 0) ...[
                      GestureDetector(
                        onTap: _goBack,
                        child: Container(
                          width: 45,
                          height: 45,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                          ),
                          child: const Icon(Icons.arrow_back, color: Colors.black, size: 20),
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'regresar',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    const Spacer(),
                    Text(
                      _isLastStep ? 'guardar' : 'siguiente',
                      style: TextStyle(
                        color: _isNextEnabled() ? Colors.white : Colors.white.withValues(alpha: 0.45),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: _isNextEnabled() ? _goNext : null,
                      child: Container(
                        width: 45,
                        height: 45,
                        decoration: BoxDecoration(
                          color: _isNextEnabled() ? Colors.white : Colors.white.withValues(alpha: 0.35),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.arrow_forward, color: _isNextEnabled() ? Colors.black : Colors.black.withValues(alpha: 0.35), size: 20),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepContent() {
    return switch (_step) {
      0 => _buildBasicStep(),
      1 => _buildProfileStep(),
      2 => _buildHealthStep(),
      3 => _buildPreventiveStep(),
      _ => _buildAttachmentsConsentStep(),
    };
  }

  Widget _buildBasicStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TitleLine(text: widget.title),
        const SizedBox(height: 32),
        const _Question(text: 'cuál es el nombre de tu caballo? (obligatorio)'),
        const SizedBox(height: 10),
        _TextFieldCard(
          controller: _nameCtrl,
          hintText: 'escribe su nombre aqui',
          borderRadius: BorderRadius.circular(12),
        ),
        const SizedBox(height: 32),
        const _Question(text: 'cuál es el sexo de tu caballo?'),
        const SizedBox(height: 10),
        _ChipGroup.single(
          value: _draft.sex,
          options: const [
            _Option('male', 'macho'),
            _Option('female', 'hembra'),
            _Option('gelding', 'castrado'),
          ],
          onChanged: (v) => setState(() => _draft.sex = v),
        ),
        const SizedBox(height: 32),
        const _Question(text: 'rango de edad'),
        const SizedBox(height: 10),
        _ChipGroup.single(
          value: _draft.ageRange,
          options: const [
            _Option('foal_0_2', 'potro (0-2 años)'),
            _Option('young_3_5', 'joven (3-5 años)'),
            _Option('adult_6_15', 'adulto (6-15 años)'),
            _Option('senior_16_plus', 'senior (16+ años)'),
          ],
          onChanged: (v) => setState(() => _draft.ageRange = v),
        ),
        const SizedBox(height: 32),
        const _Question(text: 'peso aproximado de tu caballo:'),
        const SizedBox(height: 10),
        _ChipGroup.single(
          value: _draft.weightRange,
          options: const [
            _Option('lt_400', '< 400 kg'),
            _Option('400_500', '400-500 kg'),
            _Option('500_600', '500-600 kg'),
            _Option('gt_600', '600+ kg'),
          ],
          onChanged: (v) => setState(() => _draft.weightRange = v),
        ),
        const SizedBox(height: 32),
        const _Question(text: '¿tu caballo está asegurado?'),
        const SizedBox(height: 10),
        _ChipGroup.single(
          value: _draft.isInsured == null ? null : (_draft.isInsured! ? 'yes' : 'no'),
          options: const [
            _Option('yes', 'sí'),
            _Option('no', 'no'),
          ],
          onChanged: (v) => setState(() => _draft.isInsured = v == 'yes'),
        ),
      ],
    );
  }

  Widget _buildProfileStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TitleLine(text: widget.title),
        const SizedBox(height: 32),
        const _Question(text: 'cuál es la raza de tu caballo?'),
        const SizedBox(height: 10),
        _ChipGroup.single(
          value: _draft.breed,
          options: const [
            _Option('quarter_horse', 'cuarto de milla'),
            _Option('thoroughbred', 'pura sangre'),
            _Option('pre', 'PRE'),
            _Option('arabian', 'árabe'),
            _Option('criollo', 'criollo'),
            _Option('appaloosa', 'appaloosa'),
            _Option('paint_horse', 'paint horse'),
            _Option('warmblood', 'warmblood'),
            _Option('mixed', 'mestizo'),
            _Option('other', 'otra'),
          ],
          onChanged: (v) => setState(() {
            _draft.breed = v;
            if (v != 'warmblood') _draft.warmbloodSubbreed = null;
          }),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
          alignment: Alignment.topLeft,
          child: _draft.breed == 'warmblood'
              ? Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: Colors.white.withValues(alpha: 0.04),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const _Question(text: '¿qué tipo de warmblood?'),
                            const SizedBox(height: 10),
                            _ChipGroup.single(
                              value: _draft.warmbloodSubbreed,
                              options: const [
                                _Option('kwpn', 'KWPN'),
                                _Option('hanoverian', 'Hannoveriano'),
                                _Option('oldenburg', 'Oldenburg'),
                                _Option('holsteiner', 'Holsteiner'),
                                _Option('selle_francais', 'Selle Français'),
                                _Option('westphalian', 'Westfaliano'),
                                _Option('trakehner', 'Trakehner'),
                                _Option('other', 'otro'),
                              ],
                              onChanged: (v) => setState(() => _draft.warmbloodSubbreed = v),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
        const SizedBox(height: 32),
        const _Question(text: 'qué actividad principal realiza el caballo?'),
        const SizedBox(height: 10),
        _ChipGroup.single(
          value: _singleValue(_draft.primaryActivities),
          options: const [
            _Option('competition', 'competencia'),
            _Option('regular_training', 'entrenamiento regular'),
            _Option('recreational', 'recreativo'),
            _Option('rehabilitation_recovery', 'rehabilitación / recuperación'),
            _Option('retired', 'retirado'),
          ],
          onChanged: (v) => setState(() => _draft.primaryActivities = {v}),
        ),
        const SizedBox(height: 32),
        const _Question(text: 'intensidad del entrenamiento a la semana:'),
        const SizedBox(height: 10),
        _ChipGroup.single(
          value: _draft.trainingIntensity,
          options: const [
            _Option('1_2_per_week', '1-2'),
            _Option('3_4_per_week', '3-4'),
            _Option('5_plus_per_week', '5+'),
          ],
          onChanged: (v) => setState(() => _draft.trainingIntensity = v),
        ),
        const SizedBox(height: 32),
        const _Question(text: 'sobre que tipo de terreno pisa tu caballo mayormente?'),
        const SizedBox(height: 10),
        _ChipGroup.single(
          value: _singleValue(_draft.terrains),
          options: const [
            _Option('sand', 'arena'),
            _Option('grass', 'pasto'),
            _Option('dirt', 'tierra'),
            _Option('mixed', 'mixto'),
            _Option('other', 'otro'),
          ],
          onChanged: (v) => setState(() => _draft.terrains = {v}),
        ),
      ],
    );
  }

  Widget _buildHealthStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TitleLine(text: widget.title),
        const SizedBox(height: 32),
        const _Question(text: 'en los últimos 6 meses has notado?'),
        const SizedBox(height: 10),
        _ChipGroup.multi(
          values: _draft.observedLastSixMonths,
          options: const [
            _Option('mild_lameness', 'cojera leve'),
            _Option('stiffness', 'rigidez'),
            _Option('performance_drop', 'pérdida de rendimiento'),
            _Option('appetite_changes', 'cambios de apetito'),
            _Option('none', 'ninguno de los anteriores'),
          ],
          onToggle: (v) => setState(
            () => _draft.observedLastSixMonths = _toggleMulti(_draft.observedLastSixMonths, v),
          ),
        ),
        const SizedBox(height: 32),
        const _Question(text: 'sabes si tu caballo tiene algún padecimiento?'),
        const SizedBox(height: 10),
        _ChipGroup.multi(
          values: _draft.knownConditions,
          options: const [
            _Option('digestive', 'digestivo'),
            _Option('locomotor', 'locomotor'),
            _Option('respiratory', 'respiratorio'),
            _Option('skin', 'piel'),
            _Option('none', 'ninguno'),
          ],
          onToggle: (v) => setState(
            () => _draft.knownConditions = _toggleMulti(_draft.knownConditions, v),
          ),
        ),
        const SizedBox(height: 32),
        const _Question(text: 'tu caballo está bajo algún tratamiento o tomando un suplemento actualmente?'),
        const SizedBox(height: 10),
        _TextFieldCard(
          controller: _treatmentsCtrl,
          hintText: 'indicanos cual(es)...',
          maxLines: 4,
        ),
      ],
    );
  }

  Widget _buildPreventiveStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TitleLine(text: widget.title),
        const SizedBox(height: 32),
        const _Question(text: 'recuerdas cuándo fue su última revisión veterinaria?'),
        const SizedBox(height: 10),
        _ChipGroup.single(
          value: _draft.lastVetCheck,
          options: const [
            _Option('lt_3_months', '< 3 meses'),
            _Option('3_6_months', '3-6 meses'),
            _Option('gt_6_months', '+6 meses'),
            _Option('dont_remember', 'no recuerdo'),
          ],
          onChanged: (v) => setState(() => _draft.lastVetCheck = v),
        ),
        const SizedBox(height: 32),
        const _Question(text: 'tu caballo cuenta con las vacunas al día?'),
        const SizedBox(height: 10),
        _ChipGroup.single(
          value: _draft.vaccinesUpToDate,
          options: const [
            _Option('yes', 'si'),
            _Option('no', 'no'),
            _Option('not_sure', 'no estoy seguro'),
          ],
          onChanged: (v) => setState(() => _draft.vaccinesUpToDate = v),
        ),
        const SizedBox(height: 32),
        const _Question(text: 'desparasitación:'),
        const SizedBox(height: 10),
        _ChipGroup.single(
          value: _draft.dewormingStatus,
          options: const [
            _Option('regular', 'regular'),
            _Option('irregular', 'irregular'),
            _Option('not_sure', 'no estoy seguro'),
          ],
          onChanged: (v) => setState(() => _draft.dewormingStatus = v),
        ),
        const SizedBox(height: 32),
        const _Question(text: 'a continuación puedes escribir o detallar cualquier cosa que consideres necesaria para nosotros saberlo:'),
        const SizedBox(height: 10),
        _TextFieldCard(
          controller: _notesCtrl,
          hintText: 'escribe aqui...',
          maxLines: 4,
        ),
      ],
    );
  }

  Widget _buildAttachmentsConsentStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TitleLine(text: widget.title),
        const SizedBox(height: 32),
        const _Question(text: 'adjunta fotos o videos que consideres necesario compartir con nosotros:'),
        const SizedBox(height: 24),
        _ActionPill(
          icon: Icons.photo_library_outlined,
          label: 'agregar fotos o videos',
          onTap: _pickMedia,
        ),
        if (_draft.pendingMedia.isNotEmpty) ...[
          const SizedBox(height: 12),
          _MediaMosaic(
            media: _draft.pendingMedia,
            onRemove: (index) => setState(() => _draft.pendingMedia.removeAt(index)),
          ),
        ],
      ],
    );
  }

  Set<String> _toggleMulti(Set<String> current, String value) {
    final next = <String>{...current};
    if (value == 'none') {
      if (next.contains('none')) {
        next.remove('none');
      } else {
        next
          ..clear()
          ..add('none');
      }
      return next;
    }

    next.remove('none');
    if (next.contains(value)) {
      next.remove(value);
    } else {
      next.add(value);
    }
    return next;
  }

  String? _singleValue(Set<String> values) {
    return values.isEmpty ? null : values.first;
  }
}

class _TitleLine extends StatelessWidget {
  const _TitleLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 19,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

class _Question extends StatelessWidget {
  const _Question({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 14,
        fontWeight: FontWeight.w400,
      ),
    );
  }
}

class _TextFieldCard extends StatelessWidget {
  const _TextFieldCard({
    required this.controller,
    required this.hintText,
    this.maxLines = 1,
    this.borderRadius,
  });

  final TextEditingController controller;
  final String hintText;
  final int maxLines;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(26);
    return TextField(
      controller: controller,
      maxLines: maxLines,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.28)),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.08),
        border: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _ChipGroup extends StatelessWidget {
  const _ChipGroup.single({
    required this.options,
    required this.value,
    required this.onChanged,
  })  : values = null,
        onToggle = null;

  const _ChipGroup.multi({
    required this.options,
    required this.values,
    required this.onToggle,
  })  : value = null,
        onChanged = null;

  final List<_Option> options;
  final String? value;
  final Set<String>? values;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onToggle;

  @override
  Widget build(BuildContext context) {
    final multiValues = values;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: options.map((o) {
        final selected = multiValues != null
            ? multiValues.contains(o.value)
            : value == o.value;
        return GestureDetector(
          onTap: () {
            if (multiValues != null) {
              onToggle?.call(o.value);
            } else {
              onChanged?.call(o.value);
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: selected
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.08),
            ),
            child: Text(
              o.label,
              style: TextStyle(
                color: selected ? Colors.black : Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        );
      }).toList(growable: false),
    );
  }
}

class _Option {
  const _Option(this.value, this.label);

  final String value;
  final String label;
}

class _ActionPill extends StatelessWidget {
  const _ActionPill({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          color: Colors.white.withValues(alpha: 0.08),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white70, size: 18),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaMosaic extends StatelessWidget {
  const _MediaMosaic({
    required this.media,
    required this.onRemove,
  });

  final List<_PendingMedia> media;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: media.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemBuilder: (context, index) {
        return _MediaMosaicTile(
          item: media[index],
          onRemove: () => onRemove(index),
        );
      },
    );
  }
}

class _MediaMosaicTile extends StatelessWidget {
  const _MediaMosaicTile({
    required this.item,
    required this.onRemove,
  });

  final _PendingMedia item;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (item.kind == _PendingMediaKind.image)
            Image.file(
              File(item.file.path),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _MediaFallback(kind: item.kind),
            )
          else
            _MediaFallback(kind: item.kind),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x00000000), Color(0x66000000)],
              ),
            ),
          ),
          if (item.kind == _PendingMediaKind.video)
            const Center(
              child: Icon(Icons.play_circle_fill, color: Colors.white, size: 34),
            ),
          Positioned(
            top: 6,
            right: 6,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.58),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaFallback extends StatelessWidget {
  const _MediaFallback({required this.kind});

  final _PendingMediaKind kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white.withValues(alpha: 0.08),
      child: Icon(
        kind == _PendingMediaKind.image ? Icons.image_outlined : Icons.videocam_outlined,
        color: Colors.white.withValues(alpha: 0.72),
        size: 28,
      ),
    );
  }
}

enum _PendingMediaKind { image, video }

class _PendingMedia {
  _PendingMedia({
    required this.file,
    required this.kind,
    required this.contentType,
  });

  final XFile file;
  final _PendingMediaKind kind;
  final String contentType;
}

class _HorseDraft {
  _HorseDraft({
    required this.name,
    this.sex,
    this.ageRange,
    this.weightRange,
    this.breed,
    Set<String>? primaryActivities,
    this.warmbloodSubbreed,
    this.trainingIntensity,
    Set<String>? terrains,
    Set<String>? observedLastSixMonths,
    Set<String>? knownConditions,
    this.currentTreatments = '',
    this.lastVetCheck,
    this.vaccinesUpToDate,
    this.dewormingStatus,
    this.additionalNotes = '',
    this.isInsured,
    this.allowPreventiveSuggestions = false,
    this.acceptsDisclaimer = false,
    List<_PendingMedia>? pendingMedia,
  })  : primaryActivities = primaryActivities ?? <String>{},
      terrains = terrains ?? <String>{},
      observedLastSixMonths = observedLastSixMonths ?? <String>{},
      knownConditions = knownConditions ?? <String>{},
      pendingMedia = pendingMedia ?? <_PendingMedia>[];

  String name;
  String? sex;
  String? ageRange;
  String? weightRange;
  String? breed;
  String? warmbloodSubbreed;
  Set<String> primaryActivities;
  String? trainingIntensity;
  Set<String> terrains;
  Set<String> observedLastSixMonths;
  Set<String> knownConditions;
  String currentTreatments;
  String? lastVetCheck;
  String? vaccinesUpToDate;
  String? dewormingStatus;
  String additionalNotes;
  bool? isInsured;
  bool allowPreventiveSuggestions;
  bool acceptsDisclaimer;
  List<_PendingMedia> pendingMedia;

  factory _HorseDraft.empty() => _HorseDraft(name: '');

  factory _HorseDraft.fromPet(Map<String, dynamic> pet) {
    return _HorseDraft(
      name: (pet['name']?.toString() ?? '').trim(),
      sex: _asText(pet['sex']),
      ageRange: _asText(pet['age_range']),
      weightRange: _asText(pet['weight_range']),
      breed: _asText(pet['breed']),
      warmbloodSubbreed: _asText(pet['warmblood_subbreed']),
      primaryActivities: _asTextSet(pet['primary_activities'] ?? pet['primary_activity']),
      trainingIntensity: _asText(pet['training_intensity']),
      terrains: _asTextSet(pet['terrains'] ?? pet['terrain']),
      observedLastSixMonths: _asTextSet(pet['observed_last_6_months']),
      knownConditions: _asTextSet(pet['known_conditions']),
      currentTreatments: _asText(pet['current_treatments_or_supplements']) ?? '',
      lastVetCheck: _asText(pet['last_vet_check']),
      vaccinesUpToDate: _asText(pet['vaccines_up_to_date']),
      dewormingStatus: _asText(pet['deworming_status']),
      additionalNotes: _asText(pet['additional_notes']) ?? '',
      isInsured: pet['is_insured'] is bool ? pet['is_insured'] as bool : null,
    );
  }

  _HorseDraft copy() {
    return _HorseDraft(
      name: name,
      sex: sex,
      ageRange: ageRange,
      weightRange: weightRange,
      breed: breed,
      warmbloodSubbreed: warmbloodSubbreed,
      primaryActivities: {...primaryActivities},
      trainingIntensity: trainingIntensity,
      terrains: {...terrains},
      observedLastSixMonths: {...observedLastSixMonths},
      knownConditions: {...knownConditions},
      currentTreatments: currentTreatments,
      lastVetCheck: lastVetCheck,
      vaccinesUpToDate: vaccinesUpToDate,
      dewormingStatus: dewormingStatus,
      additionalNotes: additionalNotes,
      isInsured: isInsured,
      allowPreventiveSuggestions: allowPreventiveSuggestions,
      acceptsDisclaimer: acceptsDisclaimer,
      pendingMedia: [...pendingMedia],
    );
  }

  Map<String, dynamic> toApiPayload({
    required String defaultCountry,
    required String defaultState,
  }) {
    final payload = <String, dynamic>{
      'name': name.trim(),
      'species': 'horse',
      'location': {
        'country': defaultCountry,
        'state_region': defaultState,
      },
    };

    void addString(String key, String? value) {
      final v = (value ?? '').trim();
      if (v.isNotEmpty) payload[key] = v;
    }

    addString('sex', sex);
    addString('age_range', ageRange);
    addString('weight_range', weightRange);
    addString('breed', breed);
    addString('warmblood_subbreed', warmbloodSubbreed);
    addString('primary_activity', primaryActivities.isEmpty ? null : primaryActivities.first);
    addString('training_intensity', trainingIntensity);
    addString('terrain', terrains.isEmpty ? null : terrains.first);
    if (observedLastSixMonths.isNotEmpty) {
      payload['observed_last_6_months'] = observedLastSixMonths.toList(growable: false);
    }
    if (knownConditions.isNotEmpty) {
      payload['known_conditions'] = knownConditions.toList(growable: false);
    }
    addString('current_treatments_or_supplements', currentTreatments);
    addString('last_vet_check', lastVetCheck);
    addString('vaccines_up_to_date', vaccinesUpToDate);
    addString('deworming_status', dewormingStatus);
    addString('additional_notes', additionalNotes);
    if (isInsured != null) payload['is_insured'] = isInsured;
    return payload;
  }

  static String? _asText(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static Set<String> _asTextSet(dynamic value) {
    if (value is String) {
      final text = value.trim();
      return text.isEmpty ? <String>{} : <String>{text};
    }
    if (value is! List) return <String>{};
    return value
        .whereType<dynamic>()
        .map((v) => v.toString().trim())
        .where((v) => v.isNotEmpty)
        .toSet();
  }
}

class _CompactCheckbox extends StatelessWidget {
  const _CompactCheckbox({
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              activeColor: Colors.white,
              checkColor: Colors.black,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.4), width: 1.5),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 11,
                fontWeight: FontWeight.w300,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
