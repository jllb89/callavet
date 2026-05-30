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
  --dart-define=CAV_AI_CHAT_DRY_RUN=false \
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
#   --dart-define=CAV_AI_CHAT_DRY_RUN=false -> uses the gateway's configured AI provider (real AI)
#   --dart-define=CAV_AI_CHAT_DRY_RUN=true  -> sends dryRun=true to /ai/chat/turn for deterministic gateway smoke only
# AI chat log tags to watch:
#   [AIChat][Home]        home composer and inline chat state changes
#   [PostLogin][Routing]  auth/profile routing into home
#   [AIChat][Mobile]      auth snapshot, request, response, parsing, UI state


## LiveKit gateway webhook smoke

Set this in LiveKit Cloud as the webhook URL:

https://cav-gateway-staging-ugvx.onrender.com/video/webhooks/livekit

Before setting it, make sure the latest gateway code is deployed to Render. A 404 means the new route is not deployed yet; a 401 on the unsigned probe means the route exists and is correctly rejecting unsigned requests.

```bash
curl -sS -i https://cav-gateway-staging-ugvx.onrender.com/health | sed -n '1,20p'

curl -sS -i -X POST https://cav-gateway-staging-ugvx.onrender.com/video/webhooks/livekit \
  -H 'Content-Type: application/json' \
  --data '{}' | sed -n '1,30p'
```

Expected after gateway deploy:

```text
HTTP/2 401
{"message":"invalid_livekit_webhook_signature",...}
```

Run stale-room reconciliation manually only with the internal secret loaded in your shell:

```bash
curl -sS -i -X POST https://cav-gateway-staging-ugvx.onrender.com/video/reconcile \
  -H "x-internal-secret: $INTERNAL_LIVEKIT_RECONCILE_SECRET" \
  -H 'Content-Type: application/json' \
  --data '{"maxAgeMinutes":20,"limit":25}' | sed -n '1,80p'
```

LiveKit Cloud setup:

1. Open the LiveKit Cloud project that matches `LIVEKIT_URL` on `cav-gateway-staging`.
2. Go to Webhooks and add `https://cav-gateway-staging-ugvx.onrender.com/video/webhooks/livekit`.
3. Enable room, participant, track, and egress lifecycle events if event selection is shown.
4. Save. LiveKit signs events with the project API key/secret; do not add a separate webhook secret for this gateway endpoint.

Two-sided smoke:

1. Launch the owner app with `API_BASE_URL=https://cav-gateway-staging-ugvx.onrender.com`.
2. Start an immediate video consult from AI chat.
3. Confirm owner enters room `cav-{sessionId}` and camera/mic publish.
4. Launch the vet app with the same `API_BASE_URL`.
5. Tap the active video consult on the vet dashboard.
6. Confirm vet enters the same room and both sides see/hear each other.
7. End the call and verify `livekit_video_events.processed_at`, `video_session_lifecycle.first_both_joined_at`, and finalized video entitlement usage.


## Vet app

cd /Users/jorge/Desktop/call-a-vet/apps/vet && flutter run \
  --dart-define=SUPABASE_URL=https://oajnhvizipicnypdxcrb.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9ham5odml6aXBpY255cGR4Y3JiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjE2MDc5MzcsImV4cCI6MjA3NzE4MzkzN30.aSAu4SZVrZjxIyik50rraOmm7Ni2Wk7tFdLXDE_Jelc \
  --dart-define=API_BASE_URL=https://cav-gateway-staging-ugvx.onrender.com \
  --dart-define=DEV_FORCE_SIGNOUT_ON_START=true \
  --dart-define=BYPASS_OTP=false \
  --dart-define=VET_AUTH_DEBUG=true \
  -d "vet"