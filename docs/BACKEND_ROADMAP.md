# Backend Roadmap to Reach Subscription and Billing Quality

_Last updated: 2026-05-14 (Phase 5 staging closure and storage gate)_

## Purpose
This document sequences the backend work required so the rest of the platform reaches the same production bar as subscriptions and billing before major effort returns to the Flutter app.

## Quality Bar
"As strong as subscriptions and billing" means the following are true for a backend area:

- Schema, controller behavior, and OpenAPI contract are aligned.
- User-facing endpoints are not stub-only and do not depend on manual DB intervention.
- Auth, RLS, and entitlement checks are enforced server-side.
- Failure modes are explicit, logged, and recoverable.
- Smoke tests and focused integration tests exist for the main flow.
- Admin and operational tooling exists for support, refunds, audits, or replays where relevant.

## Current Backend Status

### Strong now
- Subscriptions, billing, pricing, and entitlement reservation/consumption.
- OTP auth hardening and post-login routing dependencies.
- Basic DB and OpenAPI discipline around the subscription surface.
- Vet discovery, specialties, availability management, referral intake and assignment, ratings, and explicit appointment transitions.
- Realtime chat, LiveKit video lifecycle, structured clinical records, encounter-linked file artifacts, notifications/admin ops, and AI triage/referral/drafting are implemented and staging-validated.

### Partial now
- Production cutover chores remain outside the backend roadmap itself: production env mirroring, backup/PITR confirmation, Stripe webhook production endpoint confirmation, and release runbook evidence.
- Retrieval quality and embeddings coverage should continue improving with real usage, but the provider/configuration path is in place and validated.

### Weak or missing now
- No known launch-blocking backend roadmap item remains open on staging as of 2026-05-14.
- Future backend enhancements are now product iteration work, especially richer AI tool/function-calling orchestration, high-acuity model escalation, and deeper analytics/evals.

## Roadmap Order

## Phase 0. Foundation and Contract Cleanup
Target: 2 weeks

Goal:
Raise the platform baseline so later work does not build on stubs, spec drift, or invisible failure modes.

Deliverables:
- [x] Audit all `stub: true`, `mode: 'stub'`, and `TODO` backend paths. Either implement them or remove them from the public contract.
	Completed on 2026-04-22: implemented the remaining public admin stubs in [services/gateway-api/src/modules/admin/admin.controller.ts](/Users/jorge/Desktop/call-a-vet/services/gateway-api/src/modules/admin/admin.controller.ts) for credits grant, vet approval, plan upsert, and analytics; removed the unsupported coupon endpoint from [docs/openapi/openapi.yaml](/Users/jorge/Desktop/call-a-vet/docs/openapi/openapi.yaml); replaced the placeholder Stripe portal flow in [services/gateway-api/src/modules/subscriptions/subscriptions.controller.ts](/Users/jorge/Desktop/call-a-vet/services/gateway-api/src/modules/subscriptions/subscriptions.controller.ts); and replaced the fake pet upload URL in [services/gateway-api/src/modules/pets/pets.controller.ts](/Users/jorge/Desktop/call-a-vet/services/gateway-api/src/modules/pets/pets.controller.ts) with a real Supabase Storage signed upload flow. Remaining `db.isStub` branches were intentionally kept as local/db-unavailable fallbacks, not product-facing fake endpoints.
- [x] Close spec and implementation mismatches, especially around `/vets`, ratings, and other documented-but-thin surfaces.
	Completed on 2026-04-22: removed unsupported `/vets`, `/me/vet`, and ratings paths from [docs/openapi/openapi.yaml](/Users/jorge/Desktop/call-a-vet/docs/openapi/openapi.yaml) and registered the video controller through [services/gateway-api/src/modules/video/video.module.ts](/Users/jorge/Desktop/call-a-vet/services/gateway-api/src/modules/video/video.module.ts) so `/video/*` is actually served by the gateway.
- [x] Add request IDs and structured logs for auth, sessions, messages, appointments, video, notes, and AI-ready flows.
	Completed on 2026-04-22: added shared request IDs and JSON request logging in [services/gateway-api/src/modules/auth/auth.interceptor.ts](/Users/jorge/Desktop/call-a-vet/services/gateway-api/src/modules/auth/auth.interceptor.ts) and expanded [services/gateway-api/src/modules/auth/request-context.service.ts](/Users/jorge/Desktop/call-a-vet/services/gateway-api/src/modules/auth/request-context.service.ts) to carry request-scoped state.
- [x] Standardize auth resolution so `claims.sub`, `auth.uid()`, and role checks behave consistently in and out of transactions.
	Completed on 2026-04-22: moved the dev UUID fallback into [services/gateway-api/src/modules/auth/auth.guard.ts](/Users/jorge/Desktop/call-a-vet/services/gateway-api/src/modules/auth/auth.guard.ts), added `requireUuidUserId()` in [services/gateway-api/src/modules/auth/request-context.service.ts](/Users/jorge/Desktop/call-a-vet/services/gateway-api/src/modules/auth/request-context.service.ts), and switched the remaining controllers that were bypassing request context in [services/gateway-api/src/modules/subscriptions/subscriptions.controller.ts](/Users/jorge/Desktop/call-a-vet/services/gateway-api/src/modules/subscriptions/subscriptions.controller.ts), [services/gateway-api/src/modules/me/me.controller.ts](/Users/jorge/Desktop/call-a-vet/services/gateway-api/src/modules/me/me.controller.ts), [services/gateway-api/src/modules/pets/pets.controller.ts](/Users/jorge/Desktop/call-a-vet/services/gateway-api/src/modules/pets/pets.controller.ts), and [services/gateway-api/src/modules/auth/otp.controller.ts](/Users/jorge/Desktop/call-a-vet/services/gateway-api/src/modules/auth/otp.controller.ts).
- [x] Add rate limits and input hardening for OTP, session start, message create, room creation, and note creation.
	Completed on 2026-04-22: added [services/gateway-api/src/modules/rate-limit/rate-limit.module.ts](/Users/jorge/Desktop/call-a-vet/services/gateway-api/src/modules/rate-limit/rate-limit.module.ts) plus endpoint guards/decorators, and applied them to OTP send, session start, session message create, session note create, and video room creation with additional payload validation.
- [x] Create a backend smoke suite that covers subscriptions, sessions, messages, appointments, notes, and video endpoints.
	Completed on 2026-04-22: added [env/scripts/smoke-backend-core.sh](/Users/jorge/Desktop/call-a-vet/env/scripts/smoke-backend-core.sh) to orchestrate the existing subscriptions, sessions, messages, appointments, session-notes, and video smoke scripts. Validated on staging on 2026-04-23 against the redeployed gateway for subscriptions, sessions, messages, appointments list access, session notes, and video room lifecycle.

Exit criteria:
- No critical OpenAPI endpoint is stub-only.
- Staging smoke tests pass for all backend areas needed by mobile and vet flows.
- Logs are sufficient to trace one user or session across gateway and chat-service.

## Phase 1. Vet Operations Backbone
Target: 2 to 3 weeks

Status:
Closed on staging on 2026-04-23. The redeployed gateway passed a fresh all-green backend core smoke rerun covering subscriptions, sessions, messages, appointments, vets, session notes, and video. The Supabase CLI workflow was also normalized the same day with a native local `supabase/` project, local mirrored migration history through `0042`, and repaired staging remote history through `0041` using `SUPABASE_DIRECT_DATABASE_URL` for CLI commands.

Goal:
Make the vet side a real backend product instead of a schema plus partial scheduling support.

Deliverables:
- [x] Add a dedicated vets module for list, detail, status, approval, specialties, and profile retrieval.
- [x] Implement availability management endpoints, not just slot reading.
- [x] Expand appointment lifecycle to a real state machine with explicit transitions.
- [x] Add vet-facing queues for upcoming appointments, active consults, pending notes, and referral intake.
- [x] Add referral and assignment primitives so cases can move from intake to a selected vet.
- [x] Implement ratings instead of leaving them as contract-only placeholders.

Exit criteria:
- Vet discovery and vet detail endpoints are real and documented.
- A vet can manage availability, receive a consult, and complete appointment state transitions without DB-console work.
- Admin approval is implemented, not stubbed.

## Phase 2. Realtime Chat and Entitlement Coupling
Target: 2 to 3 weeks

Status:
Closed on staging on 2026-04-23. The chat-service now verifies websocket JWTs, authorizes session joins against `chat_sessions`, persists websocket-originated messages into `public.messages`, records delivery and read receipts in `public.message_receipts`, supports idempotency with `client_key`, adds stable `stream_order` sequencing, and releases unused reserved entitlements when an empty room is explicitly left. Migration `0042_realtime_chat_backbone.sql` was applied to staging DB and remote Supabase history repaired through `0042`. Focused realtime smoke test passed end-to-end: owner and vet joined appointment-backed session, message persisted with idempotent resend recognized as duplicate, delivery and read receipts broadcast correctly to both participants, unauthorized join rejected with "not_found", all DB records and transcript state consistent.

Goal:
Move chat from prototype transport to a production-grade consult channel that is tied to session and entitlement state.

Deliverables:
- [x] Verify Supabase JWT on websocket connect.
- [x] Authorize room join against session membership and role.
- [x] Persist websocket-originated messages through the same source of truth used for transcript retrieval.
- [x] Implement delivery, read receipts, reconnect behavior, ordering guarantees, and idempotency.
- [x] Tie session start, reserve, commit, and release flows to the chat lifecycle so entitlements are consumed exactly once.
- [x] Add moderation and redaction hooks so transcripts remain supportable.

Exit criteria:
- Realtime chat can reconnect without losing state or producing duplicate consumption.
- Transcript output is complete and matches what participants saw.
- Unauthorized users cannot join or observe consult traffic.

## Phase 3. Video Consultation Platform
Target: 2 to 3 weeks

Status:
Closed on staging on 2026-04-28. LiveKit Cloud video rollout phases 3A through 3E are implemented and validated, including webhook persistence, lifecycle safety, recording/transcript hooks, and staging hardening smokes.

Update on 2026-04-27 (implementation pass 1):
LiveKit Cloud was selected and the gateway foundation was started. The gateway now has a LiveKit server SDK dependency, LiveKit environment validation/placeholders, a dedicated LiveKit adapter service, and `/video/rooms` now issues authorized LiveKit participant tokens for existing `video` sessions instead of fake random room/token values.

Update on 2026-04-27 (implementation pass 2):
Phase 3B now routes LiveKit Cloud lifecycle events through the dedicated webhooks service at `/livekit/webhook`. The receiver verifies LiveKit authorization, persists raw room and participant events in `livekit_video_events`, and syncs room start/end state into `chat_sessions` and `clinical_encounters.video_room_id`.

Update on 2026-04-27 (implementation pass 3):
Phase 3C adds `video_session_lifecycle`, idempotent entitlement commit/release helpers, room-token entitlement reservation, forced-end settlement, and a protected `/livekit/reconcile` sweep for join-timeout and host-absent release paths.

Update on 2026-04-28 (Phase 3D – recording/transcript hooks):
Migration `0050_phase3d_egress_recording_hooks.sql` adds `egress_id`, `egress_started_at`, `egress_ended_at`, and `recording_url` to `video_session_lifecycle`. Webhooks service now handles `egress_started` and `egress_ended` LiveKit event types, storing the egress ID and recording URL when available. Gateway admin endpoint `GET /admin/video/sessions` added for paginated, filterable read of room lifecycle rows (status, entitlement outcome, egress/recording state) without DB console access. Migration applied to staging. Both services built clean.
Migrations `0048` and `0049` applied to staging. Webhooks service redeployed with SSL/pooler URL fix (`databaseConnectionOptions` strips `sslmode=require` before constructing the `pg` pool and passes explicit `ssl: { rejectUnauthorized: false }`). Signed synthetic LiveKit `room_started` event returned `200` and persisted with `processed_at` set. Render readiness endpoint confirms all config booleans true. Phase 3B and 3C are staging-validated.

Update on 2026-04-28 (Phase 3E – staging hardening):
The staging hardening pass is complete. Validations run in one pass: `env/scripts/smoke-backend-core.sh` green, signed synthetic LiveKit webhook accepted and persisted (`processed_at` set), and admin lifecycle visibility confirmed through `GET /admin/video/sessions`. A regression in the orchestrator setup was fixed by preparing a `video` session (instead of `chat`) before the video smoke step in `env/scripts/smoke-backend-core.sh`.

Goal:
Replace fake room issuance with a real video backend that behaves like subscriptions and billing do today.

Actionable rollout:
- [x] Phase 3A. Provider foundation: LiveKit Cloud decision, env vars, SDK adapter, token issuance, and smoke contract.
- [x] Phase 3B. Lifecycle webhooks: verify LiveKit webhook auth, persist room/participant events, and sync session state. Staging-validated 2026-04-28.
- [x] Phase 3C. Entitlement safety: handle room start/end, join timeout, reconnect, host absent, forced end, and entitlement finalize/release paths. Staging-validated 2026-04-28.
- [x] Phase 3D. Recording/transcript hooks: add event hooks and admin visibility even if recording/transcription stays disabled initially. Implemented and staging-validated 2026-04-28.
- [x] Phase 3E. Staging hardening: run two-participant smoke, backend core smoke, and failure-mode smokes as deployment gates. Staging-validated 2026-04-28.

Deliverables:
- [x] Choose and integrate the room provider: LiveKit Cloud.
- [x] Implement authenticated LiveKit room creation and participant token issuance for existing video sessions.
- [x] Bind token issuance to session membership and user role.
- [x] Sync room start and end events with session state.
- [x] Wire entitlement consumption/release decisions to verified room lifecycle events.
- [x] Handle join timeout, host absent, reconnect, and forced room end cases.
- [x] Add recording or transcript event hooks even if transcription is deferred to a later phase. Egress hooks implemented 2026-04-28 (migration 0050).

Exit criteria:
- Two authenticated participants can complete a staged video consult end to end.
- Session, room, and entitlement state stay consistent under retries and disconnects.
- Video failure modes are visible to support and recoverable.

## Phase 4. Structured Clinical Record for Horses
Target: 3 weeks

Status:
Closed on staging on 2026-04-23. Migration `0043_horse_kyc_schema.sql` and follow-up migrations `0045_phase4_clinical_encounters.sql` and `0046_phase4_clinical_record_hardening.sql` are applied on staging and mirrored in Supabase CLI history. The post-redeploy Phase 4 deployment gate smoke (`env/scripts/smoke-phase4-clinical-record.sh`) passed on staging with `PASS=11 FAIL=0`.

Update on 2026-04-23:
Clinical encounter backbone implementation started with migration `0045_phase4_clinical_encounters.sql` (mirrored in `packages/db/migrations`). This introduces `public.clinical_encounters`, links `consultation_notes`, `image_cases`, and `care_plans` via `encounter_id`, and adds `ensure_clinical_encounter()` to consistently bind session-linked artifacts into one encounter timeline.

Update on 2026-04-23 (post-redeploy full pass):
Migration `0046_phase4_clinical_record_hardening.sql` added a structured horse health profile model (`public.pet_health_profiles`), structured clinical note fields (`assessment_text`, `diagnosis_text`, `follow_up_instructions`, `next_follow_up_at`, `severity`), and encounter-linked file artifacts (`public.encounter_files`). Gateway endpoints now expose `/pets/:petId/health-profile`, enrich `/sessions/:sessionId/notes`, and extend encounter timeline reads (`/pets/:petId/encounters`, `/encounters/:encounterId`) with files, session/appointment context, and health profile payloads.

Goal:
Move from free-text notes and loosely linked artifacts to a real clinical record that future AI and referral logic can trust.

Deliverables:
- [x] Add a structured horse health profile covering conditions, medications, allergies, vaccines, injuries, procedures, and key history.
- [x] Add an encounter record model linked to appointment, session, video room, files, and image cases.
- [x] Expand consultation notes into structured assessment, diagnosis, plan, and follow-up fields.
- [x] Rework care plans so they are clinician-owned artifacts with explicit approval and fulfillment workflows.
- [x] Tighten access control across pets, encounters, notes, files, and image cases.

Exit criteria:
- Each consult creates a structured record that can be queried by future consults and AI tools.
- Image cases, files, and notes are all linked back to the encounter timeline.
- The backend exposes a stable medical-history surface to the app.

## Phase 5. AI Triage, Referral, and Drafting Layer
Target: 3 to 4 weeks

Status:
Closed on staging on 2026-05-14. Migration `0051_phase5_ai_triage_referral_drafting.sql` is applied and repaired in Supabase migration history, OpenAI Responses API provider configuration is deployed with `gpt-5.4-mini`, dry-run and real-provider AI validation pass, and the Phase 4 clinical file artifact gate is green after the Supabase JS Node 20 WebSocket transport fix.

Update on 2026-05-11 (implementation pass 1):
Migration `0051_phase5_ai_triage_referral_drafting.sql` was added and mirrored in `packages/db/migrations`. It introduces AI feature flags, prompt versions, `ai_events`, and reviewable `ai_drafts` with RLS/indexes. Gateway now has an `AiModule` with OpenAI-compatible provider abstraction, prompt loading, feature checks, audit/event persistence, dry-run mode for deployment validation, and embedding generation through configured `vector_targets`. Authenticated endpoints added: `POST /ai/triage`, `POST /ai/referrals/recommend`, `POST /ai/drafts/consultation-note`, `POST /ai/drafts/care-plan`, `POST /ai/embeddings/generate`, `GET /ai/drafts`, `PATCH /ai/drafts/:draftId/review`, and `GET /ai/events`. OpenAPI is updated and `env/scripts/smoke-phase5-ai.sh` validates dry-run drafts, events, and embedding generation without requiring external model credentials. Gateway API compiles successfully.

Update on 2026-05-14 (staging closure):
Gateway AI provider integration was updated to OpenAI's current Responses API with strict structured outputs and `store: false`. Render staging AI env vars are configured for `AI_API_MODE=responses`, `AI_MODEL=gpt-5.4-mini`, `AI_EMBEDDING_MODEL=text-embedding-3-small`, and `AI_REASONING_EFFORT=low`. Staging validation passed: `env/scripts/smoke-phase5-ai.sh` returned `PASS=7 FAIL=0`; a real-provider triage request returned `ok=true`, `provider=openai`, `model=gpt-5.4-mini`; and a real embedding request returned `provider=openai`, `model=text-embedding-3-small` with `persist=false`. The separate deployed file-storage blocker was fixed in gateway commit `f953e4a` by providing the `ws` transport to Supabase JS clients on Render Node 20; plain storage upload/download and `env/scripts/smoke-phase4-clinical-record.sh` now pass on staging (`PASS=11 FAIL=0`).

Goal:
Add AI only after the transport, record, and entitlement layers are trustworthy.

Deliverables:
- [x] Add a provider abstraction for model calls, prompt versioning, audit logs, and feature flags.
- [x] Implement triage intake that uses health profile, recent encounters, image cases, and KB context.
- [x] Add vet referral recommendation with explainable output and guardrails.
- [x] Add AI drafting for consultation notes and care-plan suggestions.
- [x] Add review workflow so AI suggestions are editable and never auto-publish critical clinical decisions.
- [x] Add embedding generation jobs so vector retrieval no longer depends on ad hoc backfills.
- [x] Configure AI provider credentials and run real-provider staging validation in addition to dry-run smoke. Production should mirror the same env set during cutover.

Exit criteria:
- AI output is reviewable, attributable, and easy to disable.
- Referral and drafting flows improve speed without bypassing clinical review.
- Retrieval quality is good enough to support triage and note drafting.

## Phase 6. Notifications, Admin Operations, and Go-Live Hardening
Target: 2 weeks

Status:
Closed on staging on 2026-04-28 after ops alert hardening, runbook completion, and post-redeploy gate validation.

Update on 2026-04-23 (implementation pass 1):
Migration `0047_phase6_notifications_admin_ops.sql` was added (mirrored in `packages/db/migrations`) to introduce `public.notification_events` and `public.admin_audit_logs`. Gateway now supports event-driven notifications through `/notifications/events`, and admin operational tooling was expanded with `/admin/notifications/events`, `/admin/audit/logs`, `/admin/export/sessions`, `/admin/export/notes`, and `/admin/ops/dashboard`. Smoke scripts were updated to cover these new Phase 6 surfaces.

Update on 2026-04-28 (implementation pass 2):
Notification triggers integrated into all key workflows: appointments (scheduled, consult.start, consult.end), sessions (consult.start, consult.end), payments (payment.failed via Stripe event handlers), and notes (note.ready). Injected NotificationsService into AppointmentsController, SessionsController, InternalStripeService, and SessionNotesController with fire-and-forget (non-blocking) notification hooks on state transitions. All admin endpoints for notifications, audit logs, export/sessions, export/notes, and ops/dashboard are fully functional. Gateway API compiles without errors and is ready for staging deployment and smoke testing.

Update on 2026-04-28 (post-redeploy validation):
Staging gateway redeployed with DI fix (`NotificationsService` exported from `NotificationsModule`) and startup crash resolved. Validation gates passed: `/health` and `/version` returned 200, `env/scripts/smoke-backend-core.sh` completed successfully, and notification persistence/admin visibility verified via `env/scripts/smoke-notifications-send.sh` + `env/scripts/smoke-admin-ops.sh` (`notification_events` rows visible, including expected failed-provider states such as SendGrid `Unauthorized` in sandbox credentials mismatch cases).

Update on 2026-04-28 (hardening closure):
`GET /admin/ops/dashboard` now exposes explicit alert coverage for notification failures/queue depth, video failure modes, room issuance failures, websocket auth failures, and AI job errors (with safe fallback when optional telemetry tables are absent). `env/scripts/smoke-admin-ops.sh` now enforces these alert keys as a deployment gate. Operational runbooks were finalized in `PRODUCTION_CHECKLIST.md` for backups/restore drills, webhook replay, refund side effects, and incident handling. Post-redeploy validation on staging passed with both `env/scripts/smoke-admin-ops.sh` and `env/scripts/smoke-backend-core.sh` green.

Goal:
Bring non-billing operations up to the same production standard as billing support flows.

Deliverables:
- Implement notification events and templates for appointment reminders, vet assignment, consult start, consult end, payment failure, and note ready.
- Finish admin TODO surfaces or remove them from the contract.
- Add audit and export tools for sessions, notes, AI events, and entitlements.
- Add dashboards and alerts for session failures, websocket auth failures, room issuance, and AI job errors.
- Write runbooks for backups, replay, refund side effects, and incident handling.

Exit criteria:
- Support can diagnose and resolve operational issues without direct DB intervention.
- Alerts exist for the critical failure modes introduced by chat, video, and AI.
- The backend is ready for heavier mobile and vet-app traffic.

## Cross-Cutting Rules
These rules apply to every phase:

- Update OpenAPI in the same sprint as the controller change.
- Add or update smoke tests before calling a phase complete.
- Review RLS and role boundaries for every new table or endpoint.
- Keep unfinished features behind flags instead of exposing half-complete behavior to Flutter.
- Prefer one source of truth per domain instead of duplicating logic across gateway, chat-service, and clients.

## Recommended Backend-First Stop Point Before Returning to Flutter
The safe point to return to major Flutter work has been reached. Phases 0 through 6 and the Phase 5 AI layer are closed on staging, with the backend core, admin ops, clinical record/file artifact, and AI smoke gates green.

Reason:
- By then, the app can depend on stable contracts for vet discovery, appointments, chat, video, and medical history.
- AI can start in parallel after that because it depends on structured encounter and history data.
- Returning to Flutter earlier would force UI work on unstable or stubbed backend capabilities.

## Suggested Execution Order for the Next 30 Days
- Final backend smoke validation rerun completed on 2026-04-23 after redeploy and targeted regression fixes: consolidated staging suite result `PASS=19 FAIL=0`.
- Validation note: interpreter-aware suite execution is required (`zsh` shebang scripts must not be forced through `bash`), otherwise false negatives appear (for example, `print: command not found`) that do not reflect backend runtime health.
- Phase 0 staging validation completed on 2026-04-23; keep the backend core smoke suite green as a deployment gate.
- Phase 1 closed on staging on 2026-04-23 with a fresh all-green backend core smoke rerun, including the new vet-operations coverage.
- Supabase CLI is now normalized around the native `supabase/` project; use `SUPABASE_DIRECT_DATABASE_URL` for CLI migration commands, with local mirrored history currently spanning `0035` through `0049`.
- LiveKit Cloud was selected on 2026-04-27; Phase 3A gateway token issuance, Phase 3B webhook ingestion, and Phase 3C entitlement safety are implemented and staging-validated on 2026-04-28 (signed webhook persists, readiness green, Render webhooks service healthy).
- Define the encounter and horse-history schema during Phase 1 so chat and video events can link into it cleanly.
- Phase 2 staging proof is complete; keep `env/scripts/smoke-realtime-phase2.mjs` green as a gate for chat-service deploys.
- Phase 3D recording/transcript hooks are implemented and staging-validated on 2026-04-28 (migration 0050, egress event handling in webhooks, admin GET /admin/video/sessions).
- Phase 3E staging hardening is now closed on 2026-04-28: backend core smoke green, signed LiveKit webhook persistence verified, and admin video lifecycle endpoint confirmed.
- Phase 4 is now closed on staging; keep `env/scripts/smoke-phase4-clinical-record.sh` green as an ongoing deployment gate for clinical-record changes.
- Phase 6 implementation pass 2 completed on 2026-04-28: notification triggers integrated into appointments (scheduled/start/end), sessions (start/end), payments (failure), and notes (ready). All admin endpoints functional (notifications/events, audit/logs, export/sessions, export/notes, ops/dashboard). Gateway API compiles without errors.
- Phase 6 post-redeploy gate passed on 2026-04-28 after exporting `NotificationsService` from `NotificationsModule`: gateway startup stable, backend core smoke green, and notification event persistence visible from admin tooling.
- Phase 6 is now closed on staging on 2026-04-28: notification/admin hardening complete with enforced ops alert coverage and documented runbooks.
- Phase 5 (AI triage/referral/drafting) is closed on staging on 2026-05-14: migration `0051` applied/history-repaired, OpenAI Responses API configured, dry-run smoke green, real-provider triage green, and real embedding request green.
- Backend-first stop point reached on 2026-05-14. Return to Flutter/mobile work, while keeping `env/scripts/smoke-backend-core.sh`, `zsh env/scripts/smoke-admin-ops.sh`, `bash env/scripts/smoke-phase4-clinical-record.sh`, and `bash env/scripts/smoke-phase5-ai.sh` as deployment gates for backend changes.

## Related Files
- `services/gateway-api/src/modules/subscriptions/subscriptions.controller.ts`
- `services/gateway-api/src/modules/sessions/sessions.controller.ts`
- `services/gateway-api/src/modules/messages/session-messages.controller.ts`
- `services/gateway-api/src/modules/appointments/appointments.controller.ts`
- `services/gateway-api/src/modules/notes/session-notes.controller.ts`
- `services/gateway-api/src/modules/notes/notes.controller.ts`
- `services/gateway-api/src/modules/video/video.controller.ts`
- `services/gateway-api/src/modules/video/livekit.service.ts`
- `services/chat-service/src/modules/chat/chat.gateway.ts`
- `services/chat-service/src/modules/chat/chat.service.ts`
- `packages/db/migrations/0042_realtime_chat_backbone.sql`
- `supabase/migrations/0042_realtime_chat_backbone.sql`
- `render.yaml`
- `docs/openapi/openapi.yaml`
- `docs/openapi/openapi-chat-ws.yaml`
