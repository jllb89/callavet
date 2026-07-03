# Service Rating Survey Roadmap

## Goal

Move post-consult rating into the owner chat so the user can answer with action tags instead of typing, while preserving the existing vet-rating signal and adding app/service feedback.

The survey should start after a video/chat consult ends by asking whether the user wants to answer now. If the user declines, the app should ask again later in a compact card, similar to the vet pre-call handoff card pattern.

## Product Requirements

- Ask the owner first: `¿Quieres calificar esta consulta ahora?`
- If the owner selects yes, run the survey inside chat.
- If the owner selects no, defer it and show a later in-app survey card.
- Survey questions:
  - `¿Cómo calificas la asistencia proporcionada por parte del veterinario?`
  - `¿Cómo calificas el funcionamiento general de la aplicación?`
  - Open question: `¿Hay algo más que quieras contarnos?`
- Score answers should be action tags, not typed text:
  - `Excelente`
  - `Buena`
  - `Regular`
  - `Mala`
  - `Pésima`
- The open question should allow text input and also offer a skip action tag.
- The rating flow must happen in the same session chat the owner returns to after consult end.

## Audit Summary

### Database

Existing DB surface:

- `packages/db/migrations/0001_init.sql` creates `ratings`:
  - `id uuid primary key`
  - `session_id uuid references chat_sessions(id)`
  - `vet_id uuid references vets(id)`
  - `user_id uuid references users(id)`
  - `score int check (score between 1 and 5)`
  - `comment text`
  - `created_at timestamp default now()`
  - `search_tsv tsvector`
- Existing indexes:
  - `ratings_vet_idx`
  - `ratings_session_idx`
  - `ratings_tsv_gin`
- Existing RLS:
  - `ratings_rw` allows owner, vet, or admin access.
- `packages/db/migrations/0008_horse_phase_seed.sql` seeds a sample `ratings` row.
- Staging currently has only `ratings` among rating/survey/feedback objects.

Gaps:

- No survey table.
- No app/service score separate from vet score.
- No survey prompt state: pending, accepted, declined, completed, dismissed, or ask-later.
- No per-question answers or structured payload.
- No `updated_at`, `completed_at`, `declined_at`, or `next_prompt_at` on the current `ratings` table.
- Current `ratings` table can be reused for public vet aggregate ratings, but it is too narrow for the full survey workflow.

### Gateway/API

Existing API surface:

- `services/gateway-api/src/modules/vets/ratings.controller.ts`
  - `GET /vets/:vetId/ratings`
  - `POST /sessions/:sessionId/ratings`
- Existing `POST /sessions/:sessionId/ratings`:
  - Requires owner or admin.
  - Requires `score` integer 1-5.
  - Requires completed session for non-admin users.
  - Upserts one row per `session_id + user_id`.
  - Stores one `score` and one `comment`.
- `services/gateway-api/src/modules/vets/vets.controller.ts` and `ai.service.ts` consume `ratings` for vet average/count.
- `docs/openapi/openapi.yaml` documents the existing ratings endpoints.

Gaps:

- No endpoint to ask whether a session has a pending survey.
- No endpoint to defer a survey and set `next_prompt_at`.
- No endpoint to submit structured survey answers with vet score, app score, and open feedback.
- No endpoint to list pending surveys for the owner app on launch.
- No observability for rating prompt conversion or completion.
- Existing endpoint requires completed session, but video lifecycle can keep `chat_sessions.status = active` while call rooms end and chat continues.

### Mobile App

Existing mobile surface:

- AI chat already supports action tags through `_HandoffPanel` and `_ServiceButton` in `apps/mobile/lib/src/features/chat/presentation/chat_screen.dart`.
- Post-call flow now returns the owner to the same in-memory chat and can attach a rejoin action tag.
- No owner rating/survey UI exists in mobile.
- Screenshots/Figma show the desired survey as chat-like cards/action tags, but current screenshots are not yet backed by data/API.

Gaps:

- No chat survey state machine.
- No action-tag question renderer for non-AI survey prompts.
- No app-launch pending survey card.
- No persistence for deferred survey prompts.

## Proposed Data Model

Add `consult_surveys` as the durable workflow record and keep `ratings` as the vet aggregate/public rating source.

Suggested columns:

- `id uuid primary key default gen_random_uuid()`
- `session_id uuid not null references chat_sessions(id) on delete cascade`
- `user_id uuid not null references users(id) on delete cascade`
- `vet_id uuid references vets(id) on delete set null`
- `pet_id uuid references pets(id) on delete set null`
- `status text not null check in ('pending','accepted','declined','deferred','completed','dismissed')`
- `prompted_at timestamptz`
- `accepted_at timestamptz`
- `declined_at timestamptz`
- `deferred_at timestamptz`
- `next_prompt_at timestamptz`
- `completed_at timestamptz`
- `vet_assistance_score int check between 1 and 5`
- `app_service_score int check between 1 and 5`
- `open_feedback text`
- `source text not null default 'post_call_chat'`
- `metadata jsonb not null default '{}'::jsonb`
- `created_at timestamptz not null default now()`
- `updated_at timestamptz not null default now()`
- Unique constraint on `session_id, user_id`.

Score mapping:

- `Excelente` = 5
- `Buena` = 4
- `Regular` = 3
- `Mala` = 2
- `Pésima` = 1

Compatibility behavior:

- On survey completion, upsert `ratings.score = vet_assistance_score` and `ratings.comment = open_feedback` so existing vet aggregate ratings continue working.
- Store app/service score only in `consult_surveys` so it does not pollute vet rating averages.

## Gateway/API Roadmap

### Phase 1: Schema And Backfill Safety

- Completed: added `consult_surveys` table in `0066_consult_surveys.sql` with prompt state, vet score, app score, open feedback, metadata, and timestamps.
- Completed: added indexes:
  - `(user_id, status, next_prompt_at)` for app launch pending survey lookup.
  - `(session_id, user_id)` unique.
  - `(vet_id, completed_at desc)` for vet/service analytics.
- Completed: added owner/admin row-level RLS, comments, and updated-at trigger.
- Completed: kept app/service row-level feedback anonymous to vets. Vets continue to see only public/aggregate rating data through existing ratings surfaces.

### Phase 2: Survey API

Add a new controller or extend ratings controller:

- Completed: extended `RatingsController` with `GET /sessions/:sessionId/survey`
  - Returns existing survey or creates a pending survey candidate if consult is eligible.
- Completed: added `POST /sessions/:sessionId/survey/prompt-response`
  - Body: `{ answer: 'now' | 'later' | 'dismiss' }`
  - `now` moves to accepted.
  - `later` moves to deferred and sets `next_prompt_at` 24 hours later.
  - `dismiss` is permanent for that session.
- Completed: added `PATCH /sessions/:sessionId/survey`
  - Body: `{ vetAssistanceScore?, appServiceScore?, openFeedback?, status? }`
  - Supports incremental saves as the chat asks each question.
- Completed: added `GET /me/surveys/pending`
  - Returns deferred/pending surveys where `next_prompt_at <= now()`.
- Completed: kept `POST /sessions/:sessionId/ratings` for compatibility, and survey completion upserts `ratings.score = vetAssistanceScore` plus `openFeedback` as `ratings.comment`.
- Completed: updated OpenAPI with survey endpoints, request bodies, and schemas.

Validation:

- Completed: `pnpm --filter @cav/gateway-api run build` passes.
- Completed: dry-run migration showed only `0066_consult_surveys.sql`.
- Completed: pushed migration `0066_consult_surveys.sql` to staging.
- Completed: staging verification confirms `consult_surveys`, unique session/user index, pending lookup index, owner/admin select/update policies, and `row_count=0` before launch.
- Note: `pnpm openapi:lint` still fails on pre-existing OpenAPI issues outside this survey change, including duplicate `/sessions` keys and old missing refs.

Eligibility rules:

- Session has owner `auth.uid()`.
- Session has a vet.
- Video room has ended, or chat session is completed/ended, or post-call state exists.
- Do not prompt more than once per session at the same time.
- Do not block chat/rejoin actions.

### Phase 3: Mobile Chat Survey State Machine

- Completed: added local chat survey action state separate from AI assistant responses:

- `surveyPrompt`
- `surveyVetScore`
- `surveyAppScore`
- `surveyOpenFeedback`
- `surveyComplete`

In chat after post-call return:

1. Completed: render AI-generated post-call message.
2. Completed: render a survey prompt card/action tags:
   - `Sí, calificar ahora`
   - `Más tarde`
  - `Descartar`
3. Completed: if yes:
  - ask vet assistance question with score tags.
  - ask app/service question with score tags.
  - ask open feedback question with composer enabled and `Omitir` tag.
  - submit completed survey.
4. Completed: if later:
  - call defer endpoint.
  - continue normal chat.

Important UI rule:

- Survey action tags should reuse the visual language of existing chat service action tags, not require typing for score questions.
- The open question can use the composer, but score questions should not.

Validation:

- Completed: `flutter analyze lib/src/features/chat/presentation/chat_screen.dart lib/src/features/home/presentation/home_v2_screen.dart lib/src/core/router/app_router.dart lib/src/features/video/presentation/video_call_screen.dart` passes.

### Phase 4: App-Launch Pending Survey Card

- Completed: on app startup/home load, call `GET /me/surveys/pending`.
- Completed: if one exists, show a compact pending survey card using the same visual pattern as the vet pre-call handoff/prediagnosis card:
  - session/pet/vet summary
  - `Calificar ahora`
  - `Más tarde`
  - `Descartar`
- Completed: `Calificar ahora` navigates to `/chat/:sessionId?survey=true` and starts the in-chat survey.
- Completed: `Más tarde` defers `next_prompt_at`.
- Completed: `Descartar` marks dismissed.

Validation:

- Completed: Flutter analyze passes for the touched mobile files.

### Phase 5: Observability And Logging

- Completed: added views in `0067_consult_survey_observability.sql`:
  - `consult_survey_pending_observability`
  - `consult_survey_completion_health_24h`
  - `consult_survey_scores_rolling_30d`
- Completed: backend logs with `scope=consult_survey` already cover:
  - prompt created
  - accepted/deferred/dismissed
  - answer saved
  - survey completed
  - rating upserted
- Completed: added mobile logs:
  - `[ConsultSurvey][Chat]`
  - `[ConsultSurvey][HomeCard]`

Validation:

- Completed: dry-run migration showed only `0067_consult_survey_observability.sql`.
- Completed: pushed migration `0067_consult_survey_observability.sql` to staging.
- Completed: staging verification confirms `consult_survey_pending_observability`, `consult_survey_completion_health_24h`, and `consult_survey_scores_rolling_30d` exist and are queryable.

### Phase 6: Regression Tests And Smokes

- Completed: added fixture tests for score mapping and survey state transitions:
  - `docs/service-rating-survey-fixtures.json`
  - `scripts/eval-service-rating-survey-fixtures.js`
  - `pnpm eval:service-rating-survey-fixtures`
- Completed: added API smoke `env/scripts/smoke-consult-surveys.sh` covering:
  - create/get survey
  - defer survey
  - complete vet score/app score/open feedback
  - verify `ratings` upsert with vet score only
  - verify pending survey appears on `/me/surveys/pending`
- Pending manual smoke checklist execution:
  - post-call prompt yes path
  - post-call prompt later path
  - app relaunch pending card path
  - skip open feedback path

Validation:

- Completed: `pnpm eval:service-rating-survey-fixtures` passes with `PASS=33 FAIL=0`.
- Completed: `zsh -n env/scripts/smoke-consult-surveys.sh` passes.
- Pending after deploy: run `env/scripts/smoke-consult-surveys.sh` against an eligible staging session.

## Resolved Product Decisions

- `Más tarde` defers the survey for 24 hours.
- `Descartar` is permanent for that session.
- App/service score is anonymous to vets. Vets see aggregate/public rating data only; admins can see row-level survey details.
- Survey is never required before consult summary, chat, or rejoin access.
- Existing `ratings` rows are not required to backfill into `consult_surveys` for launch; optional analytics backfill can happen later.

## Implementation Order

1. Add `consult_surveys` schema/RLS and compatibility upsert into `ratings`.
2. Add survey API endpoints and OpenAPI updates.
3. Add in-chat survey renderer/action tags.
4. Wire post-call chat return to prompt survey after the AI post-call message.
5. Add app-launch pending survey card.
6. Add observability/logging and smoke scripts.
7. Run two-sided post-call manual smoke and regression smoke.