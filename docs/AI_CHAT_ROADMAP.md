# AI Chat Roadmap

## Goal

Build a production-ready AI concierge that receives the user's veterinary need, gathers enough context, routes to the right professional vet specialty, checks available subscription entitlements before enabling paid services, and hands off to a human vet through chat, immediate video, or scheduled video.

The AI must not diagnose, prescribe, or try to complete the consultation. Its job is intake, urgency detection, routing, entitlement-gated service activation, and handoff.

## Current Backend Inventory

- AI provider integration already exists in the gateway `ai` module and defaults to OpenAI Responses API mode.
- AI draft flows already exist for triage, referral recommendation, notes, care plans, embeddings, events, and reviewable drafts.
- Realtime chat already exists as a separate Socket.IO chat service with room join, sync, send, typing, edit, delete, receipts, and persistent messages.
- Session creation already reserves chat/video entitlement through `fn_reserve_chat` and `fn_reserve_video`, and handles overage/payment fallback.
- LiveKit room creation already checks video session access and reserves/validates video entitlement.
- Vet specialties, vet search, referrals, appointments, availability slots, and vet queue primitives already exist.
- Mobile chat UI is still a placeholder and does not yet connect to Socket.IO.

## Production Principles

- Keep OpenAI calls server-side only. Mobile calls the gateway, never OpenAI directly.
- Use Responses API function calling with strict JSON schemas and `parallel_tool_calls: false`.
- Keep the initial tool list small, explicit, and domain-specific.
- The model never receives secrets, raw SQL access, or arbitrary endpoint access.
- The server fills known IDs from auth/session context instead of asking the model to invent them.
- Service activation is always gated by existing entitlement/overage logic before a chat/video path is returned to mobile.
- Every AI turn is auditable through `ai_events`; later production hardening should add tool-call trace rows if needed.
- The bot must escalate urgent/red-flag cases to immediate professional help or external emergency care instead of giving treatment instructions.

## Roadmap

### 1. Gateway AI Chat Turn Orchestrator

Status: core complete on 2026-05-28.

Add `POST /ai/chat/turn` in the gateway AI module.

Responsibilities:
- Accept user input, optional `petId`, optional `conversationId`, and prior UI-side messages if needed.
- Load safe user/pet/session context from DB using the authenticated user.
- Call OpenAI Responses API with strict function tools.
- Execute model-requested tools server-side.
- Send function-call outputs back to the model until it produces a final user-facing message or reaches a bounded step limit.
- Persist an `ai_events` audit row for every turn.
- Return a normalized response to mobile: assistant text, recommended service, selected specialty/vet when known, session/payment/appointment payload when a service is activated, and trace metadata.

Initial tools:
- `recommend_specialty`: Map symptoms/context to an existing `vet_specialties` row.
- `find_vets`: Find approved vets matching a specialty, ordered by approval/rating/load.
- `check_service_access`: Preflight whether a chat/video action can be enabled for the current user.
- `get_available_slots`: Fetch availability slots for a selected vet.

Deferred activation tools:
- `start_service`: Implement after routed `/sessions/start` accepts `petId`, `vetId`, and `specialtyId`.
- `schedule_video`: Implement after mobile slot confirmation UX is ready, backed by existing `/appointments`.

Acceptance criteria:
- Completed: the endpoint compiles and is authenticated.
- Completed: dry-run mode works without OpenAI for staging smoke tests.
- Completed: the OpenAI request uses strict schemas and disables parallel tool calls.
- Completed: the system prompt forbids diagnosis/prescription and forces handoff-oriented behavior.
- Completed: tool calls are allowlisted and cannot execute arbitrary names.
- Completed: every chat turn creates an `ai_events` audit row under `ai.chat_turn`.

Validation completed:
- `pnpm run build` in `services/gateway-api` passes.
- VS Code reported no errors in touched AI gateway files.
- `git diff --check` passed for roadmap and AI gateway files.

### 2. Routed Session Activation

Status: complete on 2026-05-28.

Close the gap between entitlement reservation and vet handoff.

Needed behavior:
- Immediate chat/video sessions should include `pet_id` and `vet_id` at creation time.
- The selected vet must be approved and must cover the selected specialty.
- Existing entitlement reservation must still happen before the session is returned as usable.
- Pending-payment responses must preserve the existing overage checkout behavior.

Preferred implementation:
- Extend `/sessions/start` or add an internal AI service helper to support `petId`, `vetId`, and `specialtyId`.
- Keep the logic transactional: create session, reserve entitlement, mark pending payment or active, return session payload.

Acceptance criteria:
- Completed: `/sessions/start` accepts camelCase and snake_case `petId`/`pet_id`, `vetId`/`vet_id`, and `specialtyId`/`specialty_id`.
- Completed: if `petId` is present, it must belong to the authenticated user.
- Completed: if `vetId` is present, the vet must be approved.
- Completed: if `specialtyId` and `vetId` are present, the vet must cover that specialty.
- Completed: the returned payload includes `petId`, `vetId`, and `specialtyId` when known.
- Completed: existing entitlement reservation, overage credit draw, and checkout fallback remain unchanged.
- Completed: OpenAPI request/response docs include routed-session fields.

Validation completed:
- `pnpm run build` in `services/gateway-api` passes.
- OpenAPI YAML parses successfully.
- `git diff --check` passed for roadmap, OpenAPI, and session routing files.

### 3. Mobile AI Concierge Chat

Status: core complete on 2026-05-28.

Replace the placeholder chat screen with a real chat experience.

Needed behavior:
- Completed: composer, bubbles, loading/typing state, routing chips, and service action cards.
- Completed: home AI prompt opens an inline chat conversation state and sends the first user turn automatically without leaving home.
- Completed: user input posts to `POST /ai/chat/turn` with Supabase bearer auth before a human session exists.
- Completed: prior chat turns are included as bounded UI-side history.
- Completed: AI response payload renders assistant text, urgency, recommended service, action label, specialty, vet, and remaining entitlement hints when returned by tools.
- Completed: gateway Responses API tool loop strips non-persisted response item IDs before replaying function calls with `store: false`.
- Completed: gateway chat turns now include bounded user profile, horse KYC/health profile, active subscription allowance, and recent conversation context.
- Completed: prompt behavior asks for the affected horse and minimum handoff context before recommending a service when the case is not an emergency.
- Completed: inline chat margins are wider and the composer spans the available width while growing up to six lines.
- Deferred to points 4 and 5: service activation navigation, realtime human chat transport, immediate video, scheduling, and payment-required checkout UX.

Validation completed:
- `pnpm run build` in `services/gateway-api` passes after the Responses API loop fix.
- `pnpm run build` in `services/gateway-api` passes after the richer AI chat context loader.
- `flutter analyze lib/src/features/chat/presentation/chat_screen.dart` passes.
- `flutter analyze lib/src/features/chat/presentation/chat_screen.dart lib/src/features/home/presentation/home_v2_screen.dart lib/src/core/router/app_router.dart` passes.

Mobile test setup:
- Run the Flutter app with valid `SUPABASE_URL` and `SUPABASE_ANON_KEY` dart-defines so the user can authenticate and the gateway receives a Supabase bearer token.
- Use the default `API_BASE_URL=https://staging.call-a-vet.app` or override it with `--dart-define=API_BASE_URL=<gateway-url>`.
- For real AI responses, run the app with `--dart-define=CAV_AI_CHAT_DRY_RUN=false`; the gateway uses its configured OpenAI Responses provider.
- For a gateway-only smoke test without OpenAI, run the app with `--dart-define=CAV_AI_CHAT_DRY_RUN=true`; the mobile client sends `dryRun: true` to `/ai/chat/turn`, which returns deterministic backend copy.
- From home, tap the AI composer, type a message, and send. The app stays on home, switches into the inline AI conversation state, auto-sends the first turn, and renders the AI response in the same surface.
- Watch Flutter logs tagged `[AIChat][Home]` and `[AIChat][Mobile]` for inline state entry, auth/token presence, request body summary, response status/body preview, parsed tool hints, and UI state changes. `[PostLogin][Routing]` still covers auth/profile routing into home.

### 4. Mobile Realtime Human Chat

Connect Flutter to the existing Socket.IO chat service.

Needed behavior:
- Add `socket_io_client` dependency.
- Connect to `/chat` using Supabase JWT in `auth.token`.
- Join by `sessionId`, consume `server.session.synced`, append `server.message.appended`, show typing and receipts.
- Send messages using `client.message.send` with a client idempotency key.
- Handle `payment_required`, reconnect, stale cursor sync, and offline retry.

### 5. Video And Scheduling UX

Wire AI recommendations to existing video/appointment primitives.

Needed behavior:
- Immediate video: activate or reuse video session, then call `/video/rooms` for LiveKit token.
- Scheduled video: show slots, book `/appointments`, then display appointment/session details.
- Payment/entitlement failure: show overage checkout or plan upgrade path.
- Urgent cases: bias toward immediate video and show emergency disclaimer copy.

### 6. Observability And Safety Hardening

Production checks:
- Add AI turn smoke script: intake -> specialty -> vet -> service recommendation.
- Add entitlement edge smoke tests: no plan, exhausted chat, exhausted video, overage credit, checkout fallback.
- Add red-flag eval prompts for colic, severe lameness, respiratory distress, bleeding, inability to stand.
- Add prompt/version management for `ai.chat_turn`.
- Add structured event payloads for tool name, tool result status, service decision, and refusal/escalation cases.
- Add mobile error states for provider timeout, gateway failure, payment required, no vet available, no slots available.

## Fast Implementation Order

1. Completed: add `POST /ai/chat/turn` and tool-call loop.
2. Completed: add routed session activation support for `petId` and `vetId`.
3. Completed: build mobile AI chat UI against `/ai/chat/turn`.
4. Next: add Socket.IO client and human chat transport.
5. Wire immediate video and scheduled video cards.
6. Run smoke tests and tune prompts/tools.

## Non-Negotiable Safety Prompt Rules

- Never diagnose, prescribe medication, dose medication, or claim to replace a veterinarian.
- Ask only the minimum clarifying questions required to route safely.
- Use provided specialties and vets only.
- Prefer professional handoff over long medical explanations.
- If red flags are present, recommend immediate video or local emergency veterinary care.
- Before enabling chat/video/scheduled video, ensure the server has performed the entitlement check.
