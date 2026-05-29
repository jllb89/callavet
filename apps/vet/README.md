# Call a Vet Pro (Flutter)

Vet-facing Flutter app for consultations, availability, schedules, and profile operations.

## Quick Start

```bash
cd apps/vet
flutter pub get
flutter run \
  --dart-define=SUPABASE_URL=<your-supabase-url> \
  --dart-define=SUPABASE_ANON_KEY=<your-supabase-anon-key> \
  --dart-define=API_BASE_URL=https://staging.call-a-vet.app
```

## Structure

- `lib/main.dart` initializes Supabase and launches the app.
- `lib/src/app.dart` wires Material, Riverpod, theme, and router.
- `lib/src/core/config/environment.dart` centralizes `--dart-define` values.
- `lib/src/core/router/app_router.dart` owns routes.
- `lib/src/core/theme/app_theme.dart` defines the vet app theme.
- `lib/src/features/dashboard/presentation` contains the starter vet dashboard shell.

## Next Work

- Add vet auth and post-login routing.
- Wire session queue data from the gateway.
- Add chat/video consultation views.
- Add availability, schedule, and specialty profile management.
