# Call a Vet Mobile (Flutter)

## Quick start
1. Install Flutter (stable channel) and ensure `flutter --version` works.
2. From repo root:
   ```bash
   cd apps/mobile
   flutter pub get
   flutter run \
     --dart-define=SUPABASE_URL=<your-supabase-url> \
     --dart-define=SUPABASE_ANON_KEY=<your-supabase-anon-key> \
     --dart-define=API_BASE_URL=https://staging.call-a-vet.app
   ```
   (Dark mode is enabled; uses system theme.)

## Structure
- `lib/main.dart` – app entry; initializes Supabase (SMS auth later).
- `lib/src/app.dart` – sets up theme and router.
- `lib/src/core/config/environment.dart` – build-time config (Supabase + API base URL).
- `lib/src/core/router/app_router.dart` – routes for onboarding, KYC, horse KYC, home, chat, settings, horse care.
- `lib/src/core/theme/app_theme.dart` – light/dark Material 3 themes.
- `lib/src/features/*/presentation` – placeholder screens per flow (replace with real UI from Figma).

## Env / keys
Use `--dart-define` (or a local `.vscode/launch.json`) for:
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `API_BASE_URL` (defaults to staging gateway `https://staging.call-a-vet.app`).
- `BYPASS_OTP` (`true` = skip OTP step in KYC for dev, `false` = require OTP).

## Next steps
- Pull design tokens/components from Figma and wire real UI.
- Implement Supabase SMS auth flow (OTP) and session persistence.
- Add data layer using the existing OpenAPI spec for gateway calls.
- Add navigation guards after onboarding/KYC.
