## Launch iOS simulator
flutter emulators --launch apple_ios_simulator

## Mobile project root
cd /Users/jorge/Desktop/call-a-vet/apps/mobile

## Staging (verbose debug)
cd /Users/jorge/Desktop/call-a-vet/apps/mobile && flutter run \
  --dart-define=SUPABASE_URL=https://oajnhvizipicnypdxcrb.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9ham5odml6aXBpY255cGR4Y3JiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjE2MDc5MzcsImV4cCI6MjA3NzE4MzkzN30.aSAu4SZVrZjxIyik50rraOmm7Ni2Wk7tFdLXDE_Jelc \
  --dart-define=API_BASE_URL=https://cav-gateway-staging-ugvx.onrender.com \
  --dart-define=DEV_FORCE_SIGNOUT_ON_START=true \
  --dart-define=BYPASS_OTP=false \
  --dart-define=KYC_LOCATION_DEBUG=false \
  --dart-define=KYC_FLOW_DEBUG=true \
  --dart-define=CAV_AI_CHAT_DRY_RUN=true \
  -d "vet"

## Production-like local run (quiet logs)
cd /Users/jorge/Desktop/call-a-vet/apps/mobile && flutter run \
  --dart-define=SUPABASE_URL=https://oajnhvizipicnypdxcrb.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9ham5odml6aXBpY255cGR4Y3JiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjE2MDc5MzcsImV4cCI6MjA3NzE4MzkzN30.aSAu4SZVrZjxIyik50rraOmm7Ni2Wk7tFdLXDE_Jelc \
  --dart-define=API_BASE_URL=https://cav-gateway-staging-ugvx.onrender.com \
  --dart-define=DEV_FORCE_SIGNOUT_ON_START=true \
  --dart-define=BYPASS_OTP=false \
  --dart-define=KYC_LOCATION_DEBUG=false \
  --dart-define=KYC_FLOW_DEBUG=false \
  -d "vet"

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
# Toggle AI chat dry-run:
#   --dart-define=CAV_AI_CHAT_DRY_RUN=true  -> sends dryRun=true to /ai/chat/turn for a deterministic bot smoke response
#   --dart-define=CAV_AI_CHAT_DRY_RUN=false -> uses the gateway's configured AI provider
# AI chat log tags to watch:
#   [AIChat][Home]        home composer and /chat route launch
#   [PostLogin][Routing]  router handoff into ChatScreen
#   [AIChat][Mobile]      auth snapshot, request, response, parsing, UI state