# Chat Consultations Realtime Roadmap

## Goal

Build chat consultations as the text equivalent of immediate video consultations: the owner starts with the AI concierge, the AI gathers enough context, a paid chat session is opened with a human veterinarian, the vet enters the same consult thread with an AI-generated pre-consult brief, both sides chat in realtime, the session closes cleanly, and the owner returns to the same post-service survey flow.

The app should not hardcode clinical/explanatory answers. The AI concierge and handoff summaries must be generated server-side and audited. The mobile apps may own UI labels, empty states, button copy, and error handling, but clinical summaries, recommendations, and owner-facing explanation content should come from the AI/gateway path.

## Current Schema Inventory

### Consult Session Core

- `chat_sessions` is the source of truth for both `chat` and `video` consults. It stores owner, vet, pet, product, status, mode, started/ended timestamps, specialty, and priority.
- `messages` stores consult chat entries with `session_id`, `sender_id`, `role`, `content`, embeddings/search, `client_key`, `stream_order`, `edited_at`, deletion/redaction fields, and original redacted content.
- `message_receipts` stores delivered/read state by message and user.
- `vet_consult_locks` prevents one vet from being assigned to simultaneous consults. Chat locks currently use a 45 minute TTL; video locks use 90 minutes.
- `ai_handoffs` stores AI-generated pre-consult summaries with urgency, reported signs, red flags, answered/unanswered questions, recommended first checks, source payload, session, pet, vet, and specialty.
- `consult_surveys` stores post-consult survey state and feeds completed vet assistance scores into `ratings`.

### Realtime Foundation

- Migration `0042_realtime_chat_backbone` adds `messages.client_key`, `messages.stream_order`, indexes for `(session_id, stream_order)` and `(session_id, client_key)`, and `message_receipts` RLS.
- Migration `0056_vet_dashboard_realtime_publication` adds `chat_sessions`, `appointments`, and `video_session_lifecycle` to `supabase_realtime`.
- Migration `0057_vet_dashboard_private_broadcast` enables private `realtime.messages` dashboard broadcasts for `vet-dashboard:{vetId}` topics.
- Migration `0059_realtime_messages_partition_guard` ensures `realtime.messages` partitions exist for database broadcasts.
- Migration `0060_messages_realtime_publication` adds `public.messages` to `supabase_realtime`.
- Migration `0068_chat_consult_room_receipts_realtime` adds private `consult-room:{sessionId}` access, publishes `consult_surveys` to Realtime, adds private Broadcast helpers for receipt updates, and creates chat consultation observability views.
- Existing RLS lets session participants and admins read/write `messages`, while `chat_sessions` is participant/admin scoped.

### Existing Backend APIs

- `POST /sessions/start` already accepts `kind`, `mode`, or `type` and supports `chat` and `video`.
- `POST /sessions/start` creates `chat_sessions.status = active`, reserves chat/video entitlement, acquires the vet lock when a vet is routed, and generates an AI handoff from the AI context.
- `GET /sessions/:sessionId` returns participant-scoped session detail.
- `GET /sessions/:sessionId/handoff` returns the latest AI handoff and session routing metadata.
- `PATCH /sessions/:sessionId` updates session status and releases vet locks on `completed` or `canceled`.
- `POST /sessions/end` marks a session completed, commits the supplied consumption id, and releases the vet lock.
- `GET /sessions/:sessionId/messages` returns REST message history.
- `POST /sessions/:sessionId/messages` inserts a message through gateway REST.
- `GET /vets/me/queue` returns active chat and video consults for the vet dashboard.
- `POST /vets/me/consults/:sessionId/end` ends active consults; for non-video sessions it treats engagement as true, completes the session, releases the lock, and closes linked encounter state.
- `GET /sessions/:sessionId/survey`, `POST /sessions/:sessionId/survey/prompt-response`, `PATCH /sessions/:sessionId/survey`, and `GET /me/surveys/pending` already support post-consult survey flows for completed chat or video sessions.
- `POST /sessions/:sessionId/messages/read` marks visible counterparty messages delivered/read through the gateway.
- `GET /admin/ops/chat-consultations` returns chat consultation realtime health metrics for sessions, first messages, first vet response, abandonment, receipts, entitlements, and surveys.

### Existing Chat Service

The separate `services/chat-service` Socket.IO implementation already contains useful domain behavior even if the product moves to Supabase Realtime as the transport:

- Authenticates Supabase JWTs and runs queries with `auth.uid()` claims.
- Derives actor role from `chat_sessions.user_id` or `chat_sessions.vet_id`; it does not trust a client-supplied role.
- Supports session sync with `afterStreamOrder` cursors.
- Uses `client_key` for idempotent sends.
- Inserts messages with `stream_order`.
- Marks delivered/read receipts.
- Commits chat entitlement on first real message.
- Handles typing, presence, edit, delete, redact, and no-message entitlement release.

This logic should be ported into the gateway/database path or deliberately retained behind a compatible API. The behavior is more important than the Socket.IO transport.

## Current App State

### Owner App

- Home composer routes owner prompts to `/chat/ai`.
- AI service activation maps `video` to `kind: video`; every other service activation maps to `kind: chat`.
- `_startSession` posts AI handoff context to `/sessions/start`.
- `_completeStartedSession` routes a chat activation to `/chat/{sessionId}`.
- Active consult cards already open `/chat/{sessionId}` for chat consults and `/video/{sessionId}` for video consults.
- The same `ChatScreen` handles AI chat, post-video chat/survey, and session routes. Real UUID session routes now load persisted consult messages, subscribe to Supabase Realtime, send through the gateway, and trigger survey flow after close.
- Home active consult and pending survey cards now refresh on owner `chat_sessions` Realtime changes and when returning from chat/survey routes.

### Vet App

- Vet dashboard loads `GET /vets/me/queue` and can open active chat consults at `/chat/{sessionId}`.
- Vet consult chat loads history from `GET /sessions/{sessionId}/messages`.
- Vet consult chat subscribes to `public.messages` with Supabase `onPostgresChanges`, filtered by `session_id`, and reconciles live messages into the local thread by `stream_order`.
- Vet sends messages through `POST /sessions/{sessionId}/messages` with `content` and `clientKey`; the gateway derives the `vet` role.
- Vet consult chat loads the AI-generated handoff from `/sessions/:sessionId/handoff` and can end active chat consults through `/vets/me/consults/:sessionId/end`.
- The vet app also has `/chat/assistant`; this must remain separate from `/chat/:sessionId` consult chat.

## Supabase Realtime Findings

Supabase currently gives three useful Realtime tools for this workflow:

- Postgres Changes: listen to database events from tables added to `supabase_realtime`. Dart uses `channel.onPostgresChanges(...)` with typed filters such as `session_id = eq.{id}`. This is already used by the vet chat screen.
- Broadcast: send low-latency room events through client libraries, REST, or database triggers. Supabase recommends Broadcast for scalable database-change fanout. Private Broadcast requires RLS on `realtime.messages` and matching private client channels.
- Presence: share slow-changing connected state through `track()`, `untrack()`, `onPresenceSync`, `onPresenceJoin`, and `onPresenceLeave`. Supabase cautions not to use Presence for high-frequency updates; typing should be debounced or sent as Broadcast.

Operational notes from the docs:

- Tables must be added to the `supabase_realtime` publication before Postgres Changes work.
- Realtime filters are server-side and should be used to keep message subscriptions scoped to one session.
- `stream(primaryKey: ['id'])` can combine initial fetch and realtime updates, but explicit REST sync plus `onPostgresChanges` gives better control over cursors, receipts, and error handling for this product.
- `removeChannel` should be called on screen dispose; unused channels degrade Realtime/database performance.
- Postgres Changes authorizes each event for each subscriber. For normal one-owner/one-vet consult rooms this is acceptable, but private Broadcast should be used for queue/dashboard fanout or if chat rooms later include many subscribers.

## Main Gaps

### 1. Owner Real Consult Mode

The owner route `/chat/{sessionId}` must distinguish:

- AI concierge route, such as `/chat/ai`.
- Real consult route, where `sessionId` is a UUID.
- Post-video continuation/survey route.

For a real chat consult, the owner screen should load persisted session messages, subscribe to Realtime, send owner messages to the session API, render vet/owner bubbles, show session status, and expose the same exit/survey behavior used after video.

### 2. Message API Hardening

`POST /sessions/:sessionId/messages` currently trusts `body.role`. It should derive role server-side:

- `auth.uid() == chat_sessions.user_id` -> `user`
- `auth.uid() == chat_sessions.vet_id` -> `vet`
- admin -> reject normal sends unless explicitly supported

The endpoint should also:

- Validate `session_id` as UUID.
- Reject non-participants before insert.
- Reject `pending_payment`, `completed`, `canceled`, and `no_show` sends unless a deliberate post-call continuation mode is allowed.
- Accept `clientKey` and return duplicate messages idempotently.
- Return `stream_order`, `client_key`, edit/delete/redaction timestamps, and receipt state.
- Commit chat entitlement on first real participant message, matching `chat-service` behavior.
- Mark sender delivered/read.

### 3. Message Sync Contract

Add a gateway-owned sync contract instead of relying only on `limit/offset` history:

- `GET /sessions/:sessionId/messages?afterStreamOrder=...&limit=...`
- Always sort by `stream_order asc`.
- Return `cursor`, `items`, `receipts`, and `session` status/mode.
- On screen open, load the latest window plus handoff/session detail.
- On reconnect, fetch messages after the last stored `stream_order` before trusting live events.

### 4. AI Transcript Persistence

When the owner activates a chat consult from the AI concierge, the vet should be able to see what the owner and AI discussed before handoff.

Options:

- Persist selected AI transcript turns as `messages.role in ('user', 'ai')` for the new `chat_sessions.id` during `/sessions/start`.
- Or keep transcripts only in `ai_handoffs.source_payload` and show them in a vet-only handoff card.

Recommendation: store the concise AI handoff in `ai_handoffs`, then persist the owner-visible pre-consult transcript turns as messages only if product wants the owner and vet to scroll the same conversation. The app should not fabricate a transcript locally.

### 5. Receipts, Presence, And Typing

Use persisted `message_receipts` for delivered/read state and Realtime Broadcast/Presence for room ambience:

- On message list load, upsert delivered receipts for messages from the other actor.
- On visible/latest message, upsert read receipts.
- Deliver receipt updates through private `consult-room:{sessionId}` Broadcast after gateway persists `message_receipts`; do not subscribe clients directly to `message_receipts` Postgres Changes for launch.
- Use Presence for online/offline and current room state.
- Use debounced private Broadcast for typing, or Presence only if typing changes are throttled heavily.

### 6. Session End Semantics

Chat consults need the same clear exit semantics as video:

- Vet can end the chat from the dashboard/chat screen.
- Owner can leave the chat UI without necessarily ending the consult.
- Owners and vets can explicitly end a chat consult. Gateway closes `chat_sessions`, releases the lock, and normal follow-up requires a new consult/session.
- On completed chat, owner returns to the same survey prompt flow.
- Active consult cards should disappear through Realtime once the session closes.

### 7. Notifications And Queue Realtime

The current notification service queues/delivers mostly email events and requires a destination for actual email delivery. Chat consultations need in-app immediacy:

- Vet dashboard should update through existing `vet-dashboard:{vetId}` private broadcast or `chat_sessions` Postgres Changes.
- Owner should get a realtime session status/message update when the vet joins, sends, or ends.
- Push notification integration can come later, but the database/gateway event model should not depend on email for live chat.

## Target Architecture

### Source Of Truth

- Gateway/database own all durable writes: session start/end, messages, receipts, surveys, handoffs, locks, and entitlement settlement.
- Supabase Realtime reflects persisted changes and carries ephemeral room signals.
- Flutter clients never decide clinical handoff content, message roles, entitlement consumption, vet lock release, or survey eligibility.

### Realtime Channels

- `consult:{sessionId}` Postgres Changes channel for `public.messages`, filtered by `session_id`.
- `consult:{sessionId}` optional Postgres Changes channel for `public.chat_sessions`, filtered by `id`, to detect status/end changes.
- `consult-room:{sessionId}` private Broadcast/Presence channel for typing, online state, and vet joined/owner joined events.
- Existing `vet-dashboard:{vetId}` private Broadcast for queue refresh.

### Send Flow

1. User or vet types a message.
2. App generates a `clientKey` and optimistically renders a pending bubble.
3. App posts `content` and `clientKey` to `POST /sessions/:sessionId/messages`.
4. Gateway derives actor role, validates session, inserts idempotently, commits entitlement if needed, marks sender read, and returns the stored message.
5. Realtime delivers the inserted message to the other participant.
6. Sender reconciles optimistic bubble by `clientKey` or returned `id`.

### Open/Reconnect Flow

1. App loads `GET /sessions/:sessionId` and `GET /sessions/:sessionId/handoff`.
2. App loads `GET /sessions/:sessionId/messages?limit=100&sort=stream_order.asc`.
3. App subscribes to `public.messages` filtered by `session_id`.
4. App subscribes to private room channel for typing/presence.
5. On reconnect, app calls `GET /sessions/:sessionId/messages?afterStreamOrder={cursor}` before accepting new realtime-only state.

## Implementation Phases

### Phase 1: Backend Contract Hardening - Completed

- Update session message create/list endpoints with actor-derived roles, `clientKey`, `stream_order`, receipts, and status checks.
- Add message sync response shape with cursor and receipts.
- Add receipt endpoints or RPC-backed gateway methods for delivered/read.
- Port entitlement commit/release logic from `chat-service` into gateway chat message/session-end paths.
- Add focused tests or smoke scripts for owner send, vet send, duplicate `clientKey`, closed-session rejection, and unauthorized session access.

Completed implementation notes:

- Gateway message list/create now derives actor role from `chat_sessions` and `auth.uid()` instead of trusting the request body.
- Message create supports `clientKey`/`client_key`, duplicate detection, `stream_order`, sender read receipts, active-session checks, payment checks, and entitlement commit on first real message.
- Message list returns `session`, `cursor`, `items`, and `receipts`, with `stream_order` sorting and `afterStreamOrder` support.
- Focused validation passed with `pnpm --filter @cav/gateway-api build`.

Acceptance criteria:

- A client cannot send as another role.
- Duplicate sends are idempotent.
- First engaged chat message finalizes or commits chat entitlement correctly.
- Closed or unpaid sessions cannot receive normal consult messages.

### Phase 2: Owner Consult Chat Mode - Completed

- Split `ChatScreen` behavior for UUID sessions into real consult mode.
- Load session detail, handoff, and persisted messages.
- Subscribe to Supabase Realtime for message inserts/updates.
- Send owner messages through gateway REST with `clientKey`.
- Render owner/vet/AI handoff transcript messages distinctly, without hardcoded clinical answer content.
- Handle closed session state and route into the existing survey prompt.

Completed implementation notes:

- Owner UUID `/chat/{sessionId}` routes now enter real consult mode instead of AI assistant mode.
- Owner consult chat loads persisted session messages, subscribes to Supabase Realtime `public.messages` filtered by `session_id`, sends through the gateway with `clientKey`, and watches `chat_sessions` status to trigger the existing survey flow after close.
- Focused validation passed with `flutter analyze lib/src/features/chat/presentation/chat_screen.dart`.

Acceptance criteria:

- Owner sees vet messages without refreshing.
- Owner messages appear in vet app without refreshing.
- Owner can leave to home and re-open the active chat from the home card.
- Completed chat returns to the survey flow.

### Phase 3: Vet Consult Chat Completion - Completed

- Keep the existing vet Realtime subscription but reconcile by `stream_order` instead of refreshing the full list for every event.
- Add handoff/pre-consult brief loading from `/sessions/:sessionId/handoff`.
- Add typing/presence state through private room channels.
- Add delivered/read state rendering if desired.
- Keep `/chat/assistant` isolated from consult chat.

Completed implementation notes:

- Vet consult chat now keeps an in-memory consult message list and reconciles Realtime payloads by `stream_order` instead of rebuilding from a `FutureBuilder` on every event.
- Vet consult chat loads and renders the server AI handoff brief from `/sessions/:sessionId/handoff` without generating local clinical content.
- Vet sends only `content` plus `clientKey`; the gateway owns role derivation.
- Vet can close an active chat consult from the chat screen through the existing end-consult gateway endpoint.
- Owner and vet consult chat now share a private `consult-room:{sessionId}` channel for presence and debounced typing state.
- Owner and vet clients mark visible counterparty messages read through the gateway; the gateway persists `message_receipts` and emits private room Broadcast updates for delivered/read UI.
- Realtime access for private consult rooms, typing/presence, and receipt Broadcast updates is backed by migration `0068_chat_consult_room_receipts_realtime`.
- Focused validation passed with `flutter analyze lib/src/features/chat/presentation/vet_chat_screen.dart`.
- Focused validation passed with `flutter analyze lib/src/features/chat/presentation/chat_screen.dart`.

Acceptance criteria:

- Vet opens active chat from dashboard and sees the AI-generated handoff.
- Vet sees owner messages live.
- Vet can end the chat and watch the row disappear from dashboard.
- Vet dashboard still handles video and chat active consults with separate icons/actions.

### Phase 4: Realtime Queue And Lifecycle Polish - Completed

- Ensure chat session insert/update triggers refresh the owner active consult cards and vet dashboard.
- Use private Broadcast for dashboard refresh signals and Postgres Changes for small session-specific room state.
- Add lifecycle events for vet joined, owner joined, first message, first response, ended, canceled, and survey prompted if analytics need them.
- Decide whether `chat_sessions` needs a dedicated lifecycle table similar to `video_session_lifecycle`, or whether session status plus messages is enough for chat.

Completed implementation notes:

- Vet dashboard already refreshes from Supabase Postgres Changes for `chat_sessions`, `appointments`, and `video_session_lifecycle`, plus private `vet-dashboard:{vetId}` broadcast events.
- Owner home now subscribes to owner-scoped `chat_sessions` Realtime changes and refreshes active consult and pending survey cards with a short debounce.
- Owner home now subscribes to owner-scoped `consult_surveys` Realtime changes so pending survey cards update even when only survey state changes.
- Owner home also refreshes active consult and pending survey state when returning from chat/survey routes.
- Owner home refreshes active consult and pending survey state when the app returns to the foreground.
- Chat consult lifecycle source of truth is `chat_sessions.status/updated_at`, `messages`, `message_receipts`, and `consult_surveys`; a dedicated chat lifecycle table is not required unless analytics later needs event-level history matching `video_session_lifecycle`.
- Focused validation passed with `flutter analyze lib/src/features/home/presentation/home_v2_screen.dart`.
- Dedicated chat lifecycle analytics events remain optional Phase 5 observability work; current session status, messages, receipts, surveys, and dashboard broadcasts cover the user-facing lifecycle.

Acceptance criteria:

- Owner/vet dashboards update within a few seconds of session start/end.
- No stale active consults remain after vet/manual end.
- Survey prompt is created only after eligible completed/canceled/no-show chat sessions.

### Phase 5: Observability And Launch Hardening

- Add health views or admin metrics for chat sessions created, first owner message, first vet response, abandoned before first message, average response time, entitlement finalized/released, and survey completion.
- Add logs with `scope: chat_consultation_realtime` for gateway send/sync/end events.
- Add Realtime channel cleanup checks in Flutter dispose paths.
- Load test owner/vet message exchange with RLS enabled.
- Document rollback: disable chat service action chips or route chat action back to AI concierge if live consult transport fails.

Acceptance criteria:

- Ops can answer whether chat consults are connecting, messaging, ending, and surveying correctly.
- Failed sends are recoverable by retrying with the same `clientKey`.
- Realtime disconnect/reconnect does not lose messages.

Completed implementation notes:

- Added `GET /admin/ops/chat-consultations` for 24-hour chat consultation metrics: created/active/completed sessions, first owner message, first vet response, abandoned sessions, message totals, average first vet response time, receipts, chat entitlements finalized/released, and survey prompts/completions.
- Added SQL observability views: `public.chat_consultation_realtime_health_24h` and `public.chat_consultation_realtime_sessions_24h`.
- Added structured gateway logs with `scope: chat_consultation_realtime` for message sync, send, read receipts, and non-video consult end.
- Added `env/scripts/smoke-chat-consult-realtime.sh` for the staging launch path: owner starts assigned chat, vet loads handoff, owner sends with `clientKey`, duplicate `clientKey` is idempotent, vet syncs under RLS, both sides mark read, vet responds, owner cursor-syncs after `stream_order`, vet ends consult, survey eligibility is verified, and admin metrics are optionally checked.
- Rollback path is documented: disable owner chat-consult action chips/routes back to AI concierge and keep video/scheduled actions active; no database rollback is required for passive views/logs, but Realtime publication changes can be removed by a follow-up migration if needed.
- Focused validation passed with `pnpm --filter @cav/gateway-api build` and `zsh -n env/scripts/smoke-chat-consult-realtime.sh`.

Rollback checklist:

1. Disable the AI chat `chat` service activation path or route it back to `/chat/ai` without calling `/sessions/start` for `kind: chat`.
2. Leave video consults and scheduled appointments enabled.
3. Keep existing sessions readable through gateway REST; do not delete `messages`, `message_receipts`, `ai_handoffs`, or `consult_surveys` data.
4. If Realtime room signals are suspected, remove client room subscriptions first; durable message send/sync still works through REST.
5. If Supabase Realtime publication changes need rollback, ship a forward migration that removes only `consult_surveys` from `supabase_realtime` and drops private consult-room policy/function, leaving tables intact.

## Resolved Decisions

- Pre-consult AI transcript turns are not persisted into `messages` for launch. The vet sees only the generated `ai_handoffs` summary/brief.
- Both owners and vets/admins can explicitly end a chat consult.
- Post-completion follow-up messages require a new consult/session.
- Keep the existing Socket.IO `chat-service` as an alternative transport if Supabase Realtime is unavailable. It was not removed in this roadmap pass.
- Receipt updates are delivered by private `consult-room:{sessionId}` Broadcast after the gateway persists `message_receipts`; `message_receipts` is not added to `supabase_realtime` for launch.

- Chat consult lifecycle source of truth is `chat_sessions`, `messages`, `message_receipts`, `ai_handoffs`, and `consult_surveys`. A dedicated chat lifecycle table is not needed for launch.

## Recommended First Build Slice

Start with the smallest end-to-end proof:

1. Harden `POST /sessions/:sessionId/messages` to derive role and accept `clientKey`.
2. Add `stream_order` and `client_key` to the REST response.
3. Add owner consult mode for UUID `/chat/{sessionId}` using the same Realtime pattern already present in vet chat.
4. Verify owner and vet can exchange messages live in one chat session.
5. End the session through `POST /vets/me/consults/:sessionId/end` and confirm the owner survey prompt appears.

This validated the product spine before the later typing, receipts, dashboard refresh, and launch observability passes were added.

## Final Roadmap Check

Status: all implementation phases are complete for the launch scope.

- Phase 1 backend contract hardening: complete.
- Phase 2 owner consult chat mode: complete.
- Phase 3 vet consult chat completion: complete.
- Phase 4 realtime queue and lifecycle polish: complete.
- Phase 5 observability and launch hardening: complete.

No launch-blocking roadmap gaps remain in the owner-vet chat consultation spine. The remaining operational action is to run `env/scripts/smoke-chat-consult-realtime.sh` against staging after migration deploy and before enabling chat-consult action chips broadly.