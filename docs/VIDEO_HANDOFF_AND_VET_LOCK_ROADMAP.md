# Video Handoff And Vet Lock Roadmap

## Goal

Polish the AI-to-vet handoff and video-call lifecycle so Call a Vet can safely route urgent cases, avoid double-booking vets, show useful AI-generated context to vets before they join, and handle call endings without confusing either side.

The AI-generated handoff text must come from the OpenAI provider through the gateway. The app should not use canned prediagnosis copy. The app can own state, layout, button labels, and error handling.

## Audit Summary

### Existing Schema And Data

Already present:

- `chat_sessions` stores `user_id`, `vet_id`, `pet_id`, `mode`, `status`, `started_at`, `ended_at`.
- `chat_sessions` already has `specialty_id` and `priority` from `0055_chat_session_routing_metadata.sql`.
- `messages` supports persistent session messages with `role in ('user', 'vet', 'ai')`.
- `ai_events` stores AI request/response payloads and can audit AI chat turns.
- `ai_drafts` exists for triage/referral/note/care-plan drafts, but not for owner-to-vet handoff summaries.
- `video_session_lifecycle` tracks `owner_joined_at`, `host_joined_at`, `first_both_joined_at`, `room_finished_at`, `status`, and entitlement finalization/release.
- `livekit_video_events` stores webhook events when LiveKit webhooks are configured and delivered.
- Vet dashboard realtime/broadcast triggers already watch `chat_sessions`, `appointments`, and `video_session_lifecycle`.

Missing or insufficient:

- No durable, first-class AI handoff or prediagnosis artifact tied to a specific `chat_session`.
- No explicit vet busy/lock table or atomic vet assignment guard.
- Vet availability selection currently considers active consult count, but there is no hard guarantee that the same vet cannot be selected for simultaneous calls.
- No owner/vet post-call reason state exposed to clients.
- No post-call AI-generated owner chat message or rejoin action generated after call end.

### Existing Gateway/API Surface

Already present:

- `POST /ai/chat/turn` performs AI concierge turns, tool routing, specialty recommendation, vet search, and service recommendation.
- AI tool `find_vets` ranks approved vets and includes active consult count in its ordering.
- `POST /sessions/start` creates chat/video sessions with `petId`, `vetId`, `specialtyId`, `priority`, and entitlement reservation.
- `POST /video/rooms` creates/ensures LiveKit rooms and returns join token/URL.
- `POST /video/rooms/:roomId/end` deletes the room and settles lifecycle/entitlement.
- `POST /vets/me/consults/:sessionId/end` lets vets end consults.
- Session listing/detail endpoints return active session basics.

Missing or insufficient:

- Vet routing is not transactionally locked at recommendation/activation time.
- Session creation validates vet approval/specialty but does not reject vets already in another active video consult.
- There is no endpoint like `GET /sessions/:sessionId/handoff` or `POST /ai/chat/handoff`.
- There is no endpoint for owner-side post-call AI message generation or rejoin decision.
- `video/rooms/:roomId/end` does not currently distinguish whether owner, vet, admin, webhook, or timeout ended the call for client UX.

### Existing Mobile Owner App Flow

Already present:

- AI chat collects intake and routes to chat/video/scheduled video.
- Service buttons activate `/sessions/start`.
- Immediate video navigates to `/video/:sessionId`.
- Owner video screen connects to LiveKit using `/video/rooms`.
- Owner app already sends `participantRole: owner` for LiveKit token generation.
- Owner video screen handles unexpected disconnect with a generic reconnect/error state.

Missing or insufficient:

- Owner does not return to the AI/human chat with an AI-generated post-call message.
- Owner does not receive a reason-specific message when the vet ends the call.
- Owner does not get a rejoin/reconnect action badge after accidental call end.
- Active AI conversation context is lost when navigating out of inline AI chat to video.

### Existing Vet App Flow

Already present:

- Vet dashboard lists active consults.
- Vet can open video call with `/video/:sessionId`.
- Vet video screen connects to LiveKit using `/video/rooms`.
- Vet app already sends `participantRole: vet` for LiveKit token generation.
- Vet dashboard active consult badges are now content-sized and borderless.

Missing or insufficient:

- Vet is taken directly into the video call without seeing an AI-generated handoff/prediagnosis card first.
- Vet dashboard does not surface handoff summary/case context before join.
- Vet side does not get a clear reason-specific message if owner ends the call.
- Need to confirm how long active calls stay active after owner/vet leaves and how lifecycle state maps to dashboard visibility.

## Product Decisions

### Prediagnosis Naming

Use `AI handoff summary` or `pre-consult summary` internally and in code. Avoid promising a diagnosis. The output should be factual and non-diagnostic:

- What the owner reported.
- Relevant intake answers.
- Urgency/red flags.
- Recommended specialty/service.
- Questions still unanswered.
- What the vet should verify first.

### Vet Pre-Call UX

Preferred UX:

1. Vet taps active video consult on dashboard.
2. App opens a pre-call handoff sheet/card.
3. Card shows AI-generated case context and risk flags.
4. Vet taps `Entrar a videollamada`.
5. Vet joins LiveKit room.

Do not block urgent entry on a slow AI call. If the handoff is not ready, show available structured context and allow join.

### Owner Post-Call UX

When call ends:

- Owner should return to the relevant chat/AI thread, not a generic disconnected screen.
- Chat should show an AI-generated message thanking the user and explaining what happened.
- If the call ended unexpectedly or by vet, show a rejoin/reconnect action badge.
- If the call was intentionally completed, show summary/next-step copy and do not push rejoin unless clinically/operationally appropriate.

### Vet Post-Call UX

When owner ends:

- Vet sees a simple message: owner ended the call.
- Active consult remains visible according to session status/lifecycle policy.
- Confirm lifecycle timeout/window before changing dashboard removal rules.

## Phase 0: Lifecycle And Busy-State Audit

Status: complete on 2026-07-02.

Purpose: verify current staging behavior before schema changes.

Tasks:

- Completed: queried active `chat_sessions` grouped by `vet_id`, `mode`, and `status`.
- Completed: queried recent `video_session_lifecycle` rows and compared owner/vet/both-joined/finished fields.
- Completed: queried `livekit_video_events` freshness and processing state.
- Completed: probed dedicated webhooks service and gateway fallback webhook route.
- Completed: reviewed configured LiveKit room timeouts and current end/reconcile behavior.

Findings:

- Staging currently has one vet with many active video sessions: `ff15556d-e6ac-47f8-b6d3-1a91e966ecc1` has 19 `video|active` sessions, 5 `video|pending_payment`, and 2 `chat|active` sessions in the audit snapshot. This confirms that active session state alone is not currently preventing double assignment.
- Lifecycle/session state is drifting. Aggregate snapshot for video sessions: `pending|active` = 12, `released|active` = 8, `forced_ended|canceled` = 6, `no_lifecycle|pending_payment` = 5.
- Several sessions have `video_session_lifecycle.status = released` and `room_finished_at` set, but `chat_sessions.status` remains `active`. This is a concrete bug source for dashboard active consult lists and vet busy checks.
- `POST /video/rooms/:roomId/end` calls `markVideoRoomEnded`, which settles lifecycle/entitlement but does not update `chat_sessions.status`. Vet manual end through `/vets/me/consults/:sessionId/end` does update session status, so owner/gateway room-end and vet end have inconsistent side effects.
- Dedicated webhooks service is healthy: `/health` returns `200`, `GET /livekit/webhook` returns configured `{ database: true, livekitApiKey: true, livekitSecret: true, reconcileSecret: true }`, and unsigned POST returns `400 signature_verification_failed`.
- Gateway fallback webhook route also rejects unsigned POSTs with `401 invalid_livekit_webhook_signature`.
- Despite healthy webhook endpoints, `livekit_video_events` only has 4 rows and the newest received event is `2026-04-28`. No current July LiveKit Cloud webhook events are being stored. LiveKit Cloud webhook configuration/event selection must be checked before relying on webhook-driven lifecycle.
- `LiveKitService.ensureRoom` configures `emptyTimeout: 300` seconds and `departureTimeout: 120` seconds. Tokens expire after 3600 seconds. Product policy still needs to define how long a consult remains visible/rejoinable after owner or vet leaves.
- Reconcile currently targets lifecycle rows in `pending|waiting` with `first_both_joined_at is null` older than a configurable age, but it depends on lifecycle rows being accurate.

Acceptance criteria:

- Completed: lifecycle rows are created by `/video/rooms`, but webhook-driven join/leave/finish updates are not currently flowing into `livekit_video_events` in staging.
- Completed: webhook endpoints are healthy, but LiveKit Cloud delivery appears stale or not configured to the active endpoint.
- Partial: we can inspect session creation and manual room-end behavior, but a complete owner/vet join/end lifecycle cannot be trusted until LiveKit Cloud webhook delivery is fixed.

Validation:

- Completed: SQL query report with recent video sessions and lifecycle/session status aggregates.
- Completed: LiveKit webhook health and unsigned signature probes for dedicated and gateway endpoints.
- Pending: two-sided staging smoke with verified webhook events arriving in `livekit_video_events` after LiveKit Cloud webhook configuration is corrected.

## Phase 1: Vet Busy Lock And Routing Guard

Status: implementation complete on 2026-07-02; migration push and staging concurrency smoke pending.

Purpose: prevent assigning or selecting a vet who is already in an active video consult.

Preferred schema:

- Completed: add `vet_consult_locks` table in `supabase/migrations/0062_vet_consult_locks.sql`:
  - `vet_id uuid primary key`
  - `session_id uuid not null`
  - `mode text not null`
  - `locked_at timestamptz not null default now()`
  - `expires_at timestamptz not null`
  - `released_at timestamptz`
  - `reason text`

Additional schema details:

- Completed: active lock indexes by `expires_at/mode/session_id` and `session_id`.
- Completed: RLS select policy for admins, locked vet, and session owner.
- Completed: admin-all policy for operational control.
- Completed: `fn_release_vet_consult_lock(session_id, reason)`.
- Completed: `fn_release_expired_vet_consult_locks()`.

Alternative: use transactional advisory locks plus indexed active session checks. A table is more observable.

Gateway changes:

- Completed: in AI `find_vets`, exclude vets with active, unexpired consult locks.
- Completed: in `/sessions/start`, release expired locks and enforce active lock checks before assigning a vet.
- Completed: return `vet_busy` with HTTP conflict when a selected vet is actively locked.
- Completed: release locks on generic session end, session patch close, owner/gateway video room end, and vet manual consult end.
- Completed: added stale lock reconciliation function; endpoint/job wiring remains a later operational step.

Acceptance criteria:

- Pending staging smoke: two simultaneous video sessions cannot reserve the same vet.
- Completed locally by build/static validation: busy vets are excluded from AI tool search query.
- Completed by schema/function: stale locks can expire safely through `fn_release_expired_vet_consult_locks()` and session start calls it before assignment.

Validation:

- Completed: `pnpm --filter @cav/gateway-api run build` passes.
- Completed: VS Code diagnostics report no errors in touched gateway files.
- Completed: `git diff --check` passes for migration and gateway changes.
- Completed: pushed migration `0062_vet_consult_locks.sql` to staging.
- Completed: staging object verification confirms `vet_consult_locks`, release functions, and `active_locks=0`.
- Pending: concurrent `/sessions/start` staging smoke with same vet.
- Pending: SQL check for lock row lifecycle in staging.
- Pending: AI `find_vets` staging smoke confirms busy vet excluded.

## Phase 2: AI Handoff Artifact

Purpose: generate durable AI handoff/pre-consult context for the vet from the owner AI chat.

Schema:

- Completed: added `ai_handoffs` table in `0063_ai_handoffs.sql`:
  - `id uuid primary key`
  - `session_id uuid references chat_sessions(id)`
  - `ai_event_id uuid references ai_events(id)`
  - `source_ai_event_id uuid references ai_events(id)`
  - `actor_user_id uuid`
  - `pet_id uuid`
  - `vet_id uuid`
  - `specialty_id uuid`
  - `urgency text`
  - `summary_text text`
  - `reported_signs jsonb`
  - `red_flags jsonb`
  - `questions_answered jsonb`
  - `questions_unanswered jsonb`
  - `recommended_first_checks jsonb`
  - `source_payload jsonb`
  - `created_at timestamptz`
  - `updated_at timestamptz`
- Completed: unique session constraint so each consult has one current durable handoff.
- Completed: participant RLS so owner, assigned vet, and admins can read the artifact.

Gateway changes:

- Completed: added strict AI handoff output schema separate from user-facing chat message.
- Completed: generate handoff when `/sessions/start` succeeds for AI-routed sessions with `aiContext`.
- Completed: mobile forwards prior AI chat messages, structured assistant payload metadata, source AI event ID, and routing/service context.
- Completed: provider prompt uses pet/session/vet/specialty context plus source AI event payload/tool results.
- Completed: persist the result to `ai_handoffs` and link it to `chat_sessions` and the handoff `ai_events` row.
- Completed: added `GET /sessions/:sessionId/handoff` with participant authorization and fallback session context.
- Completed: handoff instructions explicitly prohibit diagnosis, prescribing, unsupported claims, and owner-facing treatment instructions.

Acceptance criteria:

- Completed by implementation: every AI-routed video/chat session that sends `aiContext` can have a durable handoff artifact.
- Completed by implementation: handoff is generated by OpenAI Responses API, validated by strict schema, and stored.
- Completed by prompt/schema guardrails: handoff does not prescribe, diagnose, or contain unsupported claims.

Validation:

- Completed: `pnpm --filter @cav/gateway-api run build` passes.
- Completed: `flutter analyze lib/src/features/chat/presentation/chat_screen.dart` passes.
- Completed: VS Code diagnostics report no errors in touched gateway/mobile files.
- Completed: `git diff --check` passes for touched Phase 2 files.
- Completed: dry-run migration showed only `0063_ai_handoffs.sql`.
- Completed: pushed migration `0063_ai_handoffs.sql` to staging.
- Completed: staging object verification confirms migration `0063`, `ai_handoffs`, unique session index, participant select policy, and `handoff_rows=0` before smoke.
- Pending after gateway deploy: real OpenAI staging smoke through owner AI chat → `/sessions/start`.
- Pending after smoke: SQL row exists for the new AI-routed session.

## Phase 3: Vet Pre-Call Handoff Card

Purpose: show vets the AI handoff before entering a video call.

Gateway/API:

- Completed as Phase 2 backend foundation: `GET /sessions/:sessionId/handoff`.
- Completed as Phase 2 backend foundation: return handoff if ready, plus fallback session context if not.
- Optionally add `POST /sessions/:sessionId/handoff/regenerate` for admin/dev use.

Vet app:

- Completed: changed dashboard video action from direct navigation to pre-call sheet/card.
- Completed: active consult and upcoming appointment video buttons now fetch `GET /sessions/:sessionId/handoff` before join.
- Completed: card displays:
  - Horse name.
  - Urgency and specialty badges.
  - AI-generated handoff summary.
  - Red flags.
  - Owner-reported answers.
  - Unanswered questions.
  - Button: `Entrar a videollamada`.
- Completed: if handoff is loading, missing, or fetch fails, the vet can still join immediately.

Acceptance criteria:

- Completed by implementation: vet sees useful AI-generated context before joining when a handoff exists.
- Completed by implementation: vet can still join immediately if handoff fetch fails or no handoff exists.
- Completed by UI copy: no human-authored diagnosis is implied.

Validation:

- Completed: `flutter analyze lib/src/features/dashboard/presentation/vet_dashboard_screen.dart` passes.
- Pending after gateway/mobile deploy and real session creation: vet dashboard smoke for session with handoff.
- Pending after deploy: vet dashboard smoke for session without handoff/fetch failure fallback.

## Phase 4: Post-Call Reason And Owner Chat Return

Purpose: make call end UX clear and actionable.

Gateway/API:

- Completed: extended room end flow with actor role and reason:
  - owner ended
  - vet ended
  - admin ended
  - network disconnect
  - timeout/no-show
  - provider room finished
- Completed: migration `0064_video_call_end_reasons.sql` adds `end_actor_role`, `end_actor_user_id`, `end_reason`, `rejoin_eligible_until`, and `post_call_message_payload` to `video_session_lifecycle`.
- Completed: explicit `/video/rooms/:roomId/end` accepts `participantRole` and normalized reason, persists actor/reason, and returns end state.
- Completed: webhook/reconcile paths normalize provider room finish and timeout/no-show reasons.
- Completed: added `GET /video/sessions/:sessionId/end-state` for reason-aware owner/vet UX and rejoin eligibility.
- Completed: added `POST /video/sessions/:sessionId/post-call-message` for OpenAI-generated owner post-call copy.

Owner app:

- Completed: on room disconnected/end, fetch end state.
- Completed: owner-initiated end returns to `/chat/:sessionId`.
- Completed: generated post-call AI message is inserted as an assistant message in chat via route state.
- Completed: if rejoin is eligible, the disconnect screen shows a rejoin action.
- Completed: if rejoin is not eligible, the owner can return to chat with post-call context.

Vet app:

- Completed: if owner ends, vet screen shows a simple owner-ended message.
- Completed: vet returns to dashboard from the reason-aware status screen.
- Completed: if vet ends through the app, owner end state can expose rejoin eligibility.

Acceptance criteria:

- Completed by implementation: owner no longer sees generic connection failure after intentional vet/provider end state is available.
- Completed by implementation: owner can rejoin when `rejoin_eligible_until` is active.
- Completed by implementation: vet sees clear owner-ended message.
- Completed by backend state: lifecycle records normalized actor/reason and rejoin window.

Validation:

- Completed: `pnpm --filter @cav/gateway-api run build` passes.
- Completed: `flutter analyze` passes for touched owner video/chat/router files.
- Completed: `flutter analyze` passes for touched vet video file.
- Completed: pushed migration `0064_video_call_end_reasons.sql` to staging.
- Completed: staging object verification confirms migration `0064`, new lifecycle columns, and end-reason index.
- Pending after deploy: owner ends call smoke.
- Pending after deploy: vet ends call smoke and owner rejoin action.
- Pending after deploy: network disconnect simulation.

## Phase 5: Handoff And Lifecycle Observability

Purpose: make operational state visible.

Tasks:

- Completed: added observability views for active vet locks:
  - `active_vet_consult_lock_observability`
  - `vet_consult_lock_recent_events`
- Completed: added observability views for AI handoffs missing/failed/created:
  - `ai_handoff_session_observability`
  - `ai_handoff_generation_health_24h`
- Completed: added lifecycle health views for rooms, webhooks, end reasons, and stale states:
  - `video_lifecycle_observability`
  - `video_lifecycle_health_24h`
  - `recent_video_event_observability`
- Completed: added direct staging/admin smoke script `env/scripts/smoke-video-observability.sh`.

Acceptance criteria:

- Completed: `active_vet_consult_lock_observability` answers who is busy, why, since when, when the lock expires, and which session owns it.
- Completed: `ai_handoff_session_observability` answers which sessions lack handoff and whether the reason is missing generation, failure, in-progress generation, or closed session.
- Completed: `video_lifecycle_observability` answers why a call ended or what current room/lifecycle state explains it.
- Completed: `recent_video_event_observability` gives the recent LiveKit event stream for admin smoke.

Validation:

- Completed: dry-run migration showed only `0065_handoff_lifecycle_observability.sql`.
- Completed: pushed migration `0065_handoff_lifecycle_observability.sql` to staging.
- Completed: `env/scripts/smoke-video-observability.sh` selects from every Phase 5 view successfully.
- Completed: staging smoke summary currently reports:
  - `active_locks=0`
  - `handoff_missing_or_failed=9`
  - `video_lifecycle_attention=13`
  - `recent_livekit_events=0`
- Pending after deploy/live smoke: confirm new Phase 2+ sessions produce handoff rows and reason-aware lifecycle rows.

## Phase 6: Evals And Regression Tests

Purpose: protect the handoff workflow.

Tasks:

- Completed: added `docs/video-handoff-eval-fixtures.json` with AI handoff chat-history fixtures and non-diagnostic expected handoff shapes.
- Completed: added `scripts/eval-video-handoff-fixtures.js` and `pnpm eval:video-handoff-fixtures` for local fixture/schema guardrail evaluation.
- Completed: added `env/scripts/smoke-video-roadmap-regressions.sh` for credentialed two-sided staging regression smoke.
- Completed: smoke script covers vet busy lock race conditions by firing two concurrent `/sessions/start` requests for the same vet.
- Completed: smoke script covers call-end reason mapping by ending a LiveKit room as the vet and asserting `vet_ended` plus owner rejoin eligibility.
- Completed: smoke script covers handoff endpoint visibility, post-call AI message generation, and Phase 5 observability views.
- Completed: updated `COMMANDS.md` with Phase 6 regression commands and log tags.
- Completed: added structured logging across roadmap flows:
  - Backend JSON logs with `scope=video_handoff_roadmap` for sessions, AI handoffs, video lifecycle, post-call messages, and vet manual end.
  - Owner app logs tagged `[VideoRoadmap][Owner]`.
  - Vet dashboard logs tagged `[VideoRoadmap][VetDashboard]`.
  - Vet video logs tagged `[VideoRoadmap][VetVideo]`.

Acceptance criteria:

- Completed by smoke script: race conditions are caught in credentialed staging smoke.
- Completed locally: handoff fixtures are schema-valid and non-diagnostic.
- Completed by smoke script and logs: post-call UX behavior is repeatable and observable.

Validation:

- Completed: `pnpm eval:video-handoff-fixtures` passes with `PASS=60 FAIL=0`.
- Completed: `zsh -n env/scripts/smoke-video-roadmap-regressions.sh` passes.
- Completed: `zsh -n env/scripts/smoke-video-observability.sh` passes.
- Completed: `pnpm --filter @cav/gateway-api run build` passes after logging changes.
- Completed: Flutter analyze passes for touched owner and vet files.
- Completed after deploy: `env/scripts/smoke-video-roadmap-regressions.sh` passed against staging with `PASS=6 FAIL=0`.
- Completed after deploy: staging regression verified vet busy race, handoff endpoint readiness, LiveKit room creation, `vet_ended` call-end reason mapping, owner rejoin eligibility, AI post-call message generation, and Phase 5 observability smoke.

## Post-Roadmap Manual Smoke Fixes

Manual two-sided simulator smoke found two UX gaps after the deployed regression passed:

- Fixed: when vet/provider ends the room, owner now returns directly to the chat instead of staying on the video screen.
- Fixed: post-call chat can render a `Volver a videollamada` action tag from route state when rejoin is eligible.
- Fixed: vet/admin room creation can re-reserve owner video entitlement during the active rejoin window if the previous consumption was released before LiveKit webhooks marked both participants joined.
- Completed: added regression coverage for vet rejoin after `vet_ended` in `env/scripts/smoke-video-roadmap-regressions.sh`.

## Proposed Implementation Order

1. Audit and fix lifecycle/webhook visibility first.
2. Add vet busy lock schema and gateway enforcement.
3. Add AI handoff artifact generation and storage.
4. Add vet pre-call handoff card.
5. Add reason-aware post-call owner/vet UX.
6. Add observability views and smoke scripts.
7. Add regression fixtures/evals.

## Key Open Questions

- Should a vet be blocked for all consult modes or only active video consults?
- Should chat sessions also lock vets, or can vets handle multiple chats concurrently?
- What exact timeout should release a vet lock if owner never joins? Current LiveKit room `emptyTimeout` is 300 seconds and `departureTimeout` is 120 seconds, but product policy may differ.
- Should owner rejoin reopen the same session/room or create a fresh room under the same session?
- Should the vet handoff card be mandatory before join, or skippable for emergencies?
