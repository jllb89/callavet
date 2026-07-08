# Scheduled Consultations Roadmap

## Goal

Add scheduled consultations as the third AI-chat action path alongside immediate video and chat. When the user taps the existing scheduling action tag, the flow should stay inside the chat, gather the minimum scheduling details conversationally, use backend-owned OpenAI function calling to inspect availability and book the appointment, then surface the scheduled consult in a minimal home agenda.

Initial product scope shipped scheduled video first, then extended the same appointment/session model to scheduled chat with `mode='chat'` or `mode='video'`.

## Backend And Schema Audit

### Already Present

- `appointments` exists in the canonical DB migrations at `packages/db/migrations/0001_init.sql` with `id`, `session_id`, `vet_id`, `user_id`, `starts_at`, `ends_at`, `status`, and indexes for vet/user/status lookup.
- `vet_availability` exists with recurring vet windows by `vet_id`, `weekday`, `start_time`, `end_time`, and `timezone`.
- Appointment statuses were expanded in `supabase/migrations/0041_phase1_vet_operations.sql` to include `scheduled`, `confirmed`, `active`, `completed`, `no_show`, and `canceled`.
- Appointment RLS/realtime support exists in `supabase/migrations/0056_vet_dashboard_realtime_publication.sql`; actors can select their own appointments and `appointments` is added to `supabase_realtime`.
- Vet dashboard private broadcast triggers for appointment changes exist in `supabase/migrations/0057_vet_dashboard_private_broadcast.sql` and are hardened in `0058`.
- `services/gateway-api/src/modules/appointments/appointments.controller.ts` already exposes:
  - `GET /appointments` for owner/vet appointment list.
  - `POST /appointments` to create an appointment and, when `petId` is present, create a linked `chat_sessions` row with `status='scheduled'` and `mode='video'`.
  - `PATCH /appointments/:id` and `POST /appointments/:id/transitions` for status changes/rescheduling.
  - `GET /vets/:vetId/availability/slots` to compute available slots from `vet_availability` minus appointment conflicts.
- `POST /appointments` validates vet approval, specialty coverage, pet ownership, and vet conflicts with `tstzrange`.
- Appointment creation already sends a fire-and-forget `appointment.scheduled` notification.
- Activating an appointment can transition the linked session to `active` and later transition terminal appointment states back into the session.
- `services/gateway-api/src/modules/ai/ai.service.ts` already exposes OpenAI function tools for:
  - `recommend_specialty`
  - `find_vets`
  - `check_service_access`
  - `get_available_slots`
- The AI prompt already recognizes `scheduled_video` as a valid recommendation and instructs the model to use `get_available_slots` when scheduling is the best next step.
- Mobile AI chat already renders the third action tag: `Agendar consulta por videollamada`.
- Mobile currently handles that tag by sending a quick reply back into chat instead of opening a booking UI.
- Vet dashboard already consumes `upcomingAppointments` from `GET /vets/me/queue` and renders a compact upcoming appointment list with join support.

### Gaps To Close

- There is no AI function tool that actually books an appointment. `get_available_slots` can discover slots, but `schedule_video` is still marked deferred in `docs/AI_CHAT_ROADMAP.md`.
- `POST /appointments` is directly callable by mobile, but the AI chat flow does not yet expose a backend-owned booking orchestrator that validates the model-selected slot against the user confirmation.
- `GET /appointments` returns a very thin appointment shape: no pet name, vet name, specialty name, mode, or linked session details. Owner home agenda needs a richer list contract.
- `POST /appointments` creates a scheduled video session without `specialty_id` or `priority` on `chat_sessions`, even though the rest of chat/vet UI benefits from these fields.
- Slot generation ignores `vet_availability.timezone` when constructing timestamps; current SQL uses `make_timestamptz` without applying the availability row timezone. This may be acceptable for staging but should be fixed before production scheduling UX depends on it.
- Availability slots are duplicated in `AppointmentsController` and `AiService`; this is a drift risk.
- The appointment create endpoint checks conflicts but does not verify that the requested slot falls inside the vet's declared availability. It relies on callers using slot APIs correctly.
- Entitlement handling for scheduled video is not clearly consumed/reserved at booking time. Immediate video goes through session/video entitlement flow, while appointments can be created without an explicit video allowance gate in the controller.
- Owner home has an active consult button but no agenda component for scheduled/confirmed appointments.
- Owner chat has no in-chat slot picker, slot confirmation card, or scheduled appointment confirmation message.
- Scheduled chat is not modeled yet; appointment creation always creates `mode='video'` when a pet is present.

## Implementation Roadmap

### Phase 1. Normalize Scheduling Contracts

Status: completed on 2026-07-08.

Completed implementation:
- Added `AppointmentSchedulingService` as the shared backend scheduling helper.
- `GET /appointments` now returns backwards-compatible snake_case fields plus agenda-ready camelCase fields for session, vet, pet, specialty, mode, and appointment times.
- `POST /appointments` now creates a linked scheduled video `chat_sessions` row with `specialty_id`, `priority`, `status='scheduled'`, and `mode='video'`.
- Appointment creation rejects past starts, vet/specialty mismatches, pet ownership mismatches, conflicts, and slots outside declared vet availability.
- REST slot lookup and AI slot lookup now use the same service logic and timezone-aware availability windows.
- Scheduled-video entitlement policy for this pass is explicit: booking creates the scheduled appointment/session, while video entitlement remains reserved at activation/join time through the existing video/session lifecycle.

1. Extend `GET /appointments` for owner home agenda.

Return upcoming appointments for the authenticated actor with enough display data:
- `id`
- `sessionId`
- `mode`
- `status`
- `startsAt`
- `endsAt`
- `petId`, `petName`
- `vetId`, `vetName`
- `specialtyId`, `specialtyName`

Keep the endpoint backwards-compatible by adding fields rather than renaming existing snake_case fields immediately. Mobile can normalize both shapes if needed.

2. Tighten `POST /appointments`.

Add or verify:
- Appointment must be in the future with a small minimum lead time.
- Requested appointment range must be inside the vet's availability window.
- The generated linked `chat_sessions` row must include `specialty_id`, `priority`, `mode`, and `status='scheduled'`.
- Conflict checking stays transactional and keeps `tstzrange`.
- Return the same rich shape as `GET /appointments`.

3. Resolve scheduled-video entitlement policy.

Choose one explicit rule:
- Reserve video entitlement when the scheduled appointment is created.
- Or reserve video entitlement when the scheduled appointment is activated/joined.

Recommended first pass: reserve at booking time if the product promise is that a scheduled slot consumes one video consultation. If payment/overage is needed, return the same overage/pending-payment contract that immediate video uses.

4. Share slot computation.

Move duplicated slot SQL from `AiService` and `AppointmentsController` into a small gateway service, for example `AppointmentAvailabilityService`, so function calling and REST slots cannot diverge.

Acceptance criteria:
- `GET /appointments` returns agenda-ready rows for owner and vet.
- `POST /appointments` returns appointment + linked session IDs and rejects conflicts/out-of-window slots.
- Existing appointment smoke still passes.
- A direct staged booking creates a scheduled video session with vet/pet/specialty metadata.

### Phase 2. Add AI Function Calling For Booking

Status: completed on 2026-07-08.

Completed implementation:
- Added strict OpenAI function tool `schedule_video` to the AI chat tool allowlist.
- The tool requires vet, specialty, confirmed start time, duration, and a user-confirmation token before booking.
- `schedule_video` calls the same `AppointmentSchedulingService.createScheduledVideo` path as `POST /appointments`, so server-side availability/conflict validation is shared.
- `get_available_slots` now uses the shared scheduling service instead of duplicate slot SQL.
- AI prompt instructions now require slot discovery first and booking only after the user confirms one exact slot.

Add a strict `schedule_video` tool to `AiService`.

Suggested schema:

```json
{
  "vetId": "uuid",
  "petId": "uuid|null",
  "specialtyId": "uuid",
  "startsAt": "ISO datetime",
  "durationMin": 30,
  "confirmationToken": "string|null"
}
```

Implementation rules:
- The model may propose slots, but the server owns all validation.
- The tool should only book after the user has confirmed a concrete slot.
- The tool should re-check availability immediately before creation.
- The tool should call the same internal helper as `POST /appointments`, not duplicate insert logic.
- Tool output should include appointment id, session id, vet name, pet name, startsAt, endsAt, and mode.

Prompt/turn behavior:
- If the user taps scheduled video without enough context, ask for the missing scheduling fields inside chat.
- Minimum questions:
  - Which horse/patient is this for, if not already known?
  - Preferred timing window, if no slot list has been shown.
  - Confirmation of one exact slot.
- Do not ask for data already known from AI context, selected action result, or previous tool outputs.
- Do not let the model invent IDs, vets, or slots.

Acceptance criteria:
- AI can run: specialty -> vets -> available slots -> user confirms slot -> schedule_video.
- Tool traces are persisted in `ai_events` metadata for audit.
- Failed conflicts return a friendly re-pick-slots response instead of a generic error.

### Phase 3. Build In-Chat Scheduling UX

Status: completed on 2026-07-08.

Completed implementation:
- AI chat keeps scheduled-video selection inside the conversation by continuing through `/ai/chat/turn`.
- `_AiChatTurnResult` now parses `schedule_video` tool output into a typed scheduled appointment model.
- Successful booking renders a compact in-chat confirmation panel with vet name, scheduled date/time, and `Ver en agenda`.
- The scheduled-video action tag remains part of the existing three-option handoff panel.

Replace the current scheduled-video quick reply behavior in `apps/mobile/lib/src/features/chat/presentation/chat_screen.dart`.

Current behavior:
- `_activateService('scheduled_video', result)` calls `_sendQuickReply(service)` and returns.

Target behavior:
- Tapping `Agendar consulta por videollamada` starts a scheduling subflow inside the AI chat.
- The chat can show assistant questions as normal bubbles.
- Slot results render as compact selectable chips/cards inside the message action area.
- Selecting a slot sends a confirmation intent back through `/ai/chat/turn`.
- After `schedule_video` succeeds, append a confirmation card in chat with:
  - vet name
  - pet name
  - date/time
  - duration
  - status
  - primary action: `ver en agenda`

State model additions:
- Parse appointment payloads from `_AiChatTurnResult`.
- Add a `scheduledAppointment` or `appointment` payload model.
- Add message action rendering for slot choices and booking confirmation.
- Keep the flow resilient if app reloads mid-scheduling by relying on server history and `GET /appointments` for final agenda state.

Acceptance criteria:
- The user never leaves chat while selecting and confirming a slot.
- Conflict after confirmation produces updated available slots.
- Successful booking appears immediately as a chat confirmation.
- Scheduled-video still appears as one of the three action tags.

### Phase 4. Add Owner Home Agenda

Status: completed on 2026-07-08.

Completed implementation:
- Owner home now loads `GET /appointments?limit=20` alongside active consults and surveys.
- Future `scheduled` and `confirmed` appointments are normalized into `_UpcomingAppointment` and shown in a minimal `agenda:` section.
- Home subscribes to owner `appointments` realtime changes and refreshes the agenda through the existing debounce path.
- Agenda pills show MVZ, date/time, and pet name without replacing the active consult button.
- Agenda selection routes to the linked video or chat session when the appointment has a session id.

Add a minimal agenda section to `apps/mobile/lib/src/features/home/presentation/home_v2_screen.dart`.

Data:
- Fetch `GET /appointments?limit=20` on home load/refresh.
- Filter to future `scheduled` and `confirmed` appointments on the client only as a display guard; backend should already order and filter well enough for agenda use.
- Subscribe to appointment realtime changes for the owner if possible, matching the existing home sessions/surveys refresh pattern.

Minimal UI direction:
- Show only when there is at least one upcoming appointment.
- Keep it compact and consistent with the active consult pill language.
- Suggested card/pill contents:
  - `próxima consulta`
  - `MVZ {vetName}`
  - date/time
  - optional pet name if room allows
- Primary action opens the linked session route only when the appointment is joinable/active; otherwise it can stay informational in the first pass.

Future join behavior:
- At or near start time, show `entrar a videollamada` and route to `/video/{sessionId}`.
- Before start time, show date/time only or a disabled join affordance.

Acceptance criteria:
- Booking inside chat appears on home agenda after returning home.
- Agenda refreshes on app resume and appointment realtime/broadcast changes.
- The agenda does not replace the active consult button; active consults remain higher priority.

### Phase 5. Vet Experience And Lifecycle Polish

Status: completed on 2026-07-08.

Completed implementation:
- Vet queue already returns upcoming appointments with linked `session_id`, owner name, start time, and `coalesce(s.mode, 'video')`.
- Vet dashboard continues to open scheduled video appointments through the existing video join path.
- Vet dashboard now opens scheduled chat appointments through the existing consult chat route when the appointment has a chat session.
- Existing appointment lifecycle transitions preserve linked session mode when activating scheduled sessions and complete/cancel linked sessions on terminal appointment states.

Vet dashboard already has upcoming appointments. Use the existing UI, but verify the new owner-created appointments are complete enough for it.

Checks:
- Appointment row includes linked `session_id` so vet can join when appropriate.
- Vet queue shows correct owner name and start time.
- Transition to `active` updates both appointment and session.
- Ending the video completes/cancels the appointment and releases active consult state.
- Notifications fire for schedule/start/end.

Optional follow-up:
- Add vet-side confirmation/decline if product wants scheduled slots to require vet acceptance. Current backend supports `confirmed`, but creation defaults to `scheduled`.

Acceptance criteria:
- Vet dashboard shows appointments created by AI chat booking.
- Vet can join scheduled video when active.
- Terminal lifecycle updates clear owner/vet active states.

### Phase 6. Scheduled Chat Extension

Status: completed on 2026-07-08.

Completed implementation:
- `POST /appointments` now accepts `mode: 'chat' | 'video'` and defaults to `video` for compatibility.
- Appointment creation uses the shared scheduling service and creates linked scheduled `chat_sessions` rows with the requested mode.
- AI chat now exposes strict `schedule_chat` and `schedule_video` tools, both backed by the same server-side slot validation and appointment creation path.
- Owner chat parses both scheduling tool outputs into the same scheduled appointment confirmation panel.
- Owner home agenda already routes scheduled chat to `/chat/{sessionId}` and scheduled video to `/video/{sessionId}`.
- OpenAPI documents `AppointmentCreate.mode`.

After scheduled video is stable, add scheduled message consultations.

Backend changes:
- Allow `POST /appointments` to accept `mode: 'chat' | 'video'`.
- Create linked `chat_sessions` with matching mode.
- Decide whether chat appointments consume chat entitlement at booking or activation.
- Update slot/action copy so AI can distinguish scheduled chat from scheduled video.

Mobile changes:
- Add action label for scheduled chat only if product wants it separate from scheduled video.
- On agenda, route scheduled chat to `/chat/{sessionId}` when active/joinable.

Acceptance criteria:
- Scheduled chat can be booked, appears in agenda, and activates into the existing consult chat UI.

## Suggested Build Order

1. Backend contract hardening: rich `GET /appointments`, stricter `POST /appointments`, shared slot service.
2. AI `schedule_video` function tool and prompt updates.
3. Mobile chat scheduling subflow: slot cards, confirmation, result parsing.
4. Owner home agenda fetch/render/realtime refresh.
5. Vet dashboard lifecycle verification and staging smoke.
6. Scheduled chat support.

## Validation Plan

Backend:
- `cd services/gateway-api && pnpm run build`
- Existing appointment smoke: `env/scripts/smoke-appointments.sh`
- Add a new AI scheduling smoke:
  - user asks for scheduled consult
  - AI recommends scheduled video
  - tool fetches slots
  - user confirms slot
  - appointment and scheduled session are created

Mobile owner:
- `cd apps/mobile && flutter analyze lib/src/features/chat/presentation/chat_screen.dart lib/src/features/home/presentation/home_v2_screen.dart lib/src/core/router/app_router.dart`
- Manual simulator flow:
  - start AI chat
  - select scheduling action tag
  - answer scheduling questions
  - pick slot
  - confirm booking
  - return home and verify agenda

Vet:
- `cd apps/vet && flutter analyze lib/src/features/dashboard/presentation/vet_dashboard_screen.dart`
- Manual simulator flow:
  - verify appointment appears in vet dashboard
  - activate/join at start time
  - end call and verify owner/vet state clears

## Open Product Decisions

- Should scheduled video reserve entitlement at booking time or join/start time?
- Should vets explicitly confirm scheduled appointments, or does booking into declared availability auto-confirm?
- How far into the future should AI offer slots: 7 days, 14 days, or configurable by specialty?
- Should owner agenda show only next appointment or multiple upcoming appointments?
- Should scheduled chat be part of this first release or phase two after scheduled video?
