## Staging (verbose debug)
flutter run \
  --dart-define=SUPABASE_URL=https://oajnhvizipicnypdxcrb.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9ham5odml6aXBpY255cGR4Y3JiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjE2MDc5MzcsImV4cCI6MjA3NzE4MzkzN30.aSAu4SZVrZjxIyik50rraOmm7Ni2Wk7tFdLXDE_Jelc \
  --dart-define=API_BASE_URL=https://cav-gateway-staging-ugvx.onrender.com \
  --dart-define=DEV_FORCE_SIGNOUT_ON_START=true \
  --dart-define=BYPASS_OTP=false \
  --dart-define=KYC_LOCATION_DEBUG=false \
  --dart-define=KYC_FLOW_DEBUG=true \
  -d "iPhone 17 Pro Max"

## Production-like local run (quiet logs)
flutter run \
  --dart-define=SUPABASE_URL=https://oajnhvizipicnypdxcrb.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9ham5odml6aXBpY255cGR4Y3JiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjE2MDc5MzcsImV4cCI6MjA3NzE4MzkzN30.aSAu4SZVrZjxIyik50rraOmm7Ni2Wk7tFdLXDE_Jelc \
  --dart-define=API_BASE_URL=https://cav-gateway-staging-ugvx.onrender.com \
  --dart-define=DEV_FORCE_SIGNOUT_ON_START=true \
  --dart-define=BYPASS_OTP=false \
  --dart-define=KYC_LOCATION_DEBUG=false \
  --dart-define=KYC_FLOW_DEBUG=false \
  -d "iPhone 17 Pro Max"

# Toggle OTP bypass:
#   --dart-define=BYPASS_OTP=true   -> skips OTP step (dev/testing)
#   --dart-define=BYPASS_OTP=false  -> normal OTP flow
# Toggle startup sign-out (dev only):
#   --dart-define=DEV_FORCE_SIGNOUT_ON_START=true  -> clears any prior session every app launch (default in debug)
#   --dart-define=DEV_FORCE_SIGNOUT_ON_START=false -> keeps session across launches
# Toggle KYC location debug:
#   --dart-define=KYC_LOCATION_DEBUG=true  -> prints location diagnostics in UI + console
#   --dart-define=KYC_LOCATION_DEBUG=false -> hides diagnostics
# Toggle KYC flow debug:
#   --dart-define=KYC_FLOW_DEBUG=true  -> logs OTP/auth/session/profile DB flow in console
#   --dart-define=KYC_FLOW_DEBUG=false -> hides flow logs