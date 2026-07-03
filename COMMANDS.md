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
# Video handoff roadmap log tags to watch:
#   Backend JSON logs:      scope=video_handoff_roadmap component=sessions|ai|video|vets
#   [VideoRoadmap][Owner]   owner video room/create/end/end-state/post-call/rejoin
#   [VideoRoadmap][VetDashboard] vet pre-call AI handoff fetch and join path
#   [VideoRoadmap][VetVideo] vet video room/create/end/end-state

## Video handoff roadmap regression checks

Local fixture/schema eval for AI handoff guardrails:

```bash
cd /Users/jorge/Desktop/call-a-vet && pnpm eval:video-handoff-fixtures
```

Direct SQL observability smoke after sourcing staging env:

```bash
cd /Users/jorge/Desktop/call-a-vet && env/scripts/smoke-video-observability.sh
```

Credentialed two-sided regression smoke after deploying gateway/mobile/vet changes. Requires real owner/vet JWTs and matching staging IDs:

```bash
cd /Users/jorge/Desktop/call-a-vet && \
  GATEWAY_BASE=https://cav-gateway-staging-ugvx.onrender.com \
  OWNER_TOKEN="$OWNER_TOKEN" \
  VET_TOKEN="$VET_TOKEN" \
  PET_ID="$PET_ID" \
  VET_ID="$VET_ID" \
  SPECIALTY_ID="$SPECIALTY_ID" \
  env/scripts/smoke-video-roadmap-regressions.sh
```

This smoke checks vet busy lock race behavior, vet handoff endpoint visibility, vet-ended call reason mapping, owner rejoin eligibility, vet rejoin during the rejoin window, AI post-call message generation, and observability views.


## LiveKit webhook smoke

Current LiveKit Cloud webhook URL for staging:

https://cav-webhooks-staging-ugvx.onrender.com/livekit/webhook

The dedicated webhooks service should return `200` on health/readiness and reject unsigned fake events with `signature_verification_failed`. The gateway fallback route is `https://cav-gateway-staging-ugvx.onrender.com/video/livekit/webhook`.

```bash
curl -sS -i https://cav-webhooks-staging-ugvx.onrender.com/health | sed -n '1,20p'

curl -sS -i https://cav-webhooks-staging-ugvx.onrender.com/livekit/webhook | sed -n '1,45p'

curl -sS -i -X POST https://cav-webhooks-staging-ugvx.onrender.com/livekit/webhook \
  -H 'Content-Type: application/json' \
  --data '{}' | sed -n '1,30p'
```

Expected unsigned probe:

```text
HTTP/2 400
{"ok":false,"reason":"signature_verification_failed"}
```

Run stale-room reconciliation manually only with the internal secret loaded in your shell:

```bash
curl -sS -i -X POST https://cav-webhooks-staging-ugvx.onrender.com/livekit/reconcile \
  -H "x-internal-secret: $INTERNAL_LIVEKIT_RECONCILE_SECRET" \
  -H 'Content-Type: application/json' \
  --data '{"timeoutMinutes":20,"limit":25}' | sed -n '1,80p'
```

LiveKit Cloud setup:

1. Open the LiveKit Cloud project that matches the staging LiveKit credentials.
2. Go to Webhooks and confirm `https://cav-webhooks-staging-ugvx.onrender.com/livekit/webhook`.
3. Enable room, participant, track, and egress lifecycle events if event selection is shown.
4. Save. LiveKit signs events with the project API key/secret; do not add a separate webhook secret for this endpoint.

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


  Run owner app on simulator A (terminal 1)
cd /Users/jorge/Desktop/call-a-vet/apps/mobile && flutter run -d 014D86FE-511C-490C-BD95-893A67FF2774 --dart-define=SUPABASE_URL=https://oajnhvizipicnypdxcrb.supabase.co --dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9ham5odml6aXBpY255cGR4Y3JiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjE2MDc5MzcsImV4cCI6MjA3NzE4MzkzN30.aSAu4SZVrZjxIyik50rraOmm7Ni2Wk7tFdLXDE_Jelc --dart-define=API_BASE_URL=https://cav-gateway-staging-ugvx.onrender.com --dart-define=DEV_FORCE_SIGNOUT_ON_START=true --dart-define=BYPASS_OTP=false --dart-define=KYC_LOCATION_DEBUG=false --dart-define=KYC_FLOW_DEBUG=true --dart-define=CAV_AI_CHAT_DRY_RUN=false

Run vet app on simulator B (terminal 2)
cd /Users/jorge/Desktop/call-a-vet/apps/vet && flutter run -d D344C088-92BE-4393-B3A5-3E786FD17498 --dart-define=SUPABASE_URL=https://oajnhvizipicnypdxcrb.supabase.co --dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9ham5odml6aXBpY255cGR4Y3JiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjE2MDc5MzcsImV4cCI6MjA3NzE4MzkzN30.aSAu4SZVrZjxIyik50rraOmm7Ni2Wk7tFdLXDE_Jelc --dart-define=API_BASE_URL=https://cav-gateway-staging-ugvx.onrender.com --dart-define=DEV_FORCE_SIGNOUT_ON_START=true --dart-define=BYPASS_OTP=false --dart-define=VET_AUTH_DEBUG=true

pendientes: badges 