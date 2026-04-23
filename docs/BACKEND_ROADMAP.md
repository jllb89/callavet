# Backend Roadmap to Reach Subscription and Billing Quality

_Last updated: 2026-04-23_

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

### Partial now
- Sessions and HTTP message flows.
- Session notes, care plans, and image cases.
- Knowledge base and vector retrieval plumbing.

### Weak or missing now
- Production-grade realtime chat transport.
- Real video infrastructure.
- Structured horse medical record and encounter model.
- AI triage, referral, note drafting, and care-plan generation.
- Notifications and admin completeness outside billing.

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
Deferred on 2026-04-23 by product priority to focus on Phase 4 structured clinical record work first.

Goal:
Replace fake room issuance with a real video backend that behaves like subscriptions and billing do today.

Deliverables:
- Choose and integrate the room provider, likely LiveKit or equivalent.
- Implement real room and token lifecycle with authenticated joins.
- Bind room access to appointment, session, and user role.
- Sync room start and end events with session state and entitlement consumption.
- Handle join timeout, host absent, reconnect, and forced room end cases.
- Add recording or transcript event hooks even if transcription is deferred to a later phase.

Exit criteria:
- Two authenticated participants can complete a staged video consult end to end.
- Session, room, and entitlement state stay consistent under retries and disconnects.
- Video failure modes are visible to support and recoverable.

## Phase 4. Structured Clinical Record for Horses
Target: 3 weeks

Status:
Started on 2026-04-23. Migration `0043_horse_kyc_schema.sql` is applied on staging and mirrored in Supabase CLI history. `public.pets` now stores horse KYC fields as structured columns with enum and conditional constraints, array validations, indexed query surfaces, and updated search-vector rebuilding for retrieval and embedding workflows.

Goal:
Move from free-text notes and loosely linked artifacts to a real clinical record that future AI and referral logic can trust.

Deliverables:
- Add a structured horse health profile covering conditions, medications, allergies, vaccines, injuries, procedures, and key history.
- Add an encounter record model linked to appointment, session, video room, files, and image cases.
- Expand consultation notes into structured assessment, diagnosis, plan, and follow-up fields.
- Rework care plans so they are clinician-owned artifacts with explicit approval and fulfillment workflows.
- Tighten access control across pets, encounters, notes, files, and image cases.

Exit criteria:
- Each consult creates a structured record that can be queried by future consults and AI tools.
- Image cases, files, and notes are all linked back to the encounter timeline.
- The backend exposes a stable medical-history surface to the app.

## Phase 5. AI Triage, Referral, and Drafting Layer
Target: 3 to 4 weeks

Goal:
Add AI only after the transport, record, and entitlement layers are trustworthy.

Deliverables:
- Add a provider abstraction for model calls, prompt versioning, audit logs, and feature flags.
- Implement triage intake that uses health profile, recent encounters, image cases, and KB context.
- Add vet referral recommendation with explainable output and guardrails.
- Add AI drafting for session summaries, consultation notes, and care-plan suggestions.
- Add review workflow so AI suggestions are editable and never auto-publish critical clinical decisions.
- Add embedding generation jobs so vector retrieval no longer depends on ad hoc backfills.

Exit criteria:
- AI output is reviewable, attributable, and easy to disable.
- Referral and drafting flows improve speed without bypassing clinical review.
- Retrieval quality is good enough to support triage and note drafting.

## Phase 6. Notifications, Admin Operations, and Go-Live Hardening
Target: 2 weeks

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
The safe point to return to major Flutter work is after Phases 0 through 4 are complete.

Reason:
- By then, the app can depend on stable contracts for vet discovery, appointments, chat, video, and medical history.
- AI can start in parallel after that because it depends on structured encounter and history data.
- Returning to Flutter earlier would force UI work on unstable or stubbed backend capabilities.

## Suggested Execution Order for the Next 30 Days
- Phase 0 staging validation completed on 2026-04-23; keep the backend core smoke suite green as a deployment gate.
- Phase 1 closed on staging on 2026-04-23 with a fresh all-green backend core smoke rerun, including the new vet-operations coverage.
- Supabase CLI is now normalized around the native `supabase/` project; use `SUPABASE_DIRECT_DATABASE_URL` for CLI migration commands, with local mirrored history currently spanning `0035` through `0043`.
- Make a hard provider decision for video during Phase 1, even if Phase 3 implementation starts later.
- Define the encounter and horse-history schema during Phase 1 so chat and video events can link into it cleanly.
- Phase 2 staging proof is complete; keep `env/scripts/smoke-realtime-phase2.mjs` green as a gate for chat-service deploys.
- Phase 3 is intentionally deferred; prioritize Phase 4 structured clinical record rollout before resuming video infrastructure work.
- Do not add new Flutter medical-record features until Phase 4 contracts are stable.

## Related Files
- `services/gateway-api/src/modules/subscriptions/subscriptions.controller.ts`
- `services/gateway-api/src/modules/sessions/sessions.controller.ts`
- `services/gateway-api/src/modules/messages/session-messages.controller.ts`
- `services/gateway-api/src/modules/appointments/appointments.controller.ts`
- `services/gateway-api/src/modules/notes/session-notes.controller.ts`
- `services/gateway-api/src/modules/notes/notes.controller.ts`
- `services/gateway-api/src/modules/video/video.controller.ts`
- `services/chat-service/src/modules/chat/chat.gateway.ts`
- `services/chat-service/src/modules/chat/chat.service.ts`
- `packages/db/migrations/0042_realtime_chat_backbone.sql`
- `supabase/migrations/0042_realtime_chat_backbone.sql`
- `render.yaml`
- `docs/openapi/openapi.yaml`
- `docs/openapi/openapi-chat-ws.yaml`
