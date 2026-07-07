# Chat V2.0 Roadmap

## Goal

Make Call-a-Vet chat feel instant, reliable, and polished under real mobile conditions: weak cellular networks, app backgrounding, duplicate realtime events, large media uploads, expired signed URLs, and fast owner/vet back-and-forth.

Chat V2.0 is not a redesign of the current chat look. It is the reliability, speed, accessibility, and observability layer that turns the current chat into a world-class production messenger.

## Current Baseline

Already implemented:

- Durable REST message creation/listing with `stream_order` and idempotent `clientKey`.
- Supabase Realtime/Postgres subscriptions plus private Broadcast for messages, typing, receipts, and presence.
- Owner and vet text chat inside the consult flow.
- Images, videos, and voice notes in both directions.
- Native in-chat voice and video playback.
- Signed media upload/download URLs and stale URL refresh for playback retry.
- Read/delivered labels, typing status, and basic online presence.
- Admin media metrics, transcript export with signed links, audit logs, and orphan pending upload cleanup.

Implemented in the Phase 0/1 first pass:

- Attachment-safe reconciliation now preserves hydrated media when raw Postgres message events arrive without attachments.
- Owner and vet chat screens run cursor catch-up on subscribe, foreground/resume, and refresh paths using `afterStreamOrder`.
- Owner and vet sends now create stable local `clientKey` values, persist pending text/media sends to a durable app-support outbox before network calls, show sending/retrying/failed state, time out stalled sends, and reconcile the local message when REST confirms.

Implemented in the Phase 2/3 first pass:

- Owner and vet media selection now stages images, videos, and voice notes in the composer before send, with remove-before-send and a visible ready/uploading state.
- Owner and vet Realtime channels now surface reconnect status, schedule backoff reconnects after channel errors, run catch-up after resubscribe, ignore stale typing events, stop typing on send/focus loss/background, and debounce read receipts.

Remaining gap:

- The chat now has a first durable outbox, structured retry metadata with retryable-error backoff, media staging, native image/video compression before upload, real byte-level upload progress, upload cancel/retry controls, reconnect catch-up, client/backend reliability telemetry, gateway OpenTelemetry API spans, admin alert delivery hooks, an admin reliability dashboard, draft restore banners, date/unread markers, an accessibility/haptics pass, a media-processing job queue with FFmpeg/ClamAV hardening, voice transcript summarization into vet handoff context, and chat media/reliability smoke coverage. It still needs a shared repository/sync abstraction, formal Flutter reducer/widget/integration tests, dynamic-text QA, and a normalized Drift/SQLite store before it should be called world-class.

## Product Principles

- Realtime is a notification layer. The database-backed REST sync is the source of truth.
- Every sent message has a visible state: queued, sending, sent, delivered, read, failed, retrying.
- No user text or media selection disappears because of app kill, network loss, route changes, or stale Realtime channels.
- The composer stays fast even when media uploads are slow.
- The current visual chat shell stays intact; V2.0 improves behavior and micro-UX, not the overall look.
- Clinical summaries, handoff briefs, and assistant responses remain AI-generated from context, not preset canned answers.

## Target Architecture

### Client Components

- `ChatRepository`: single public API for loading, sending, retrying, marking read, and refreshing media.
- `ChatSyncEngine`: owns initial hydration, `afterStreamOrder` catch-up, reconnect recovery, foreground/resume sync, and continuity checks.
- `ChatRealtimeGateway`: wraps Supabase Realtime/Postgres/Broadcast channels and exposes typed events.
- `ChatOutboxStore`: local durable queue for text and media messages.
- `MessageReducer`: merges local, REST, Postgres, and Broadcast events without losing attachments, receipts, or local pending state.
- `MediaUploadManager`: owns signed upload URL creation, local file metadata, upload progress, cancellation, retry, compression hooks, and cleanup.
- `TypingPresenceController`: throttles typing, expires stale typing events, tracks online state, and emits accessibility announcements.
- `DeliveryReceiptController`: batches visible-read updates and reconciles delivered/read labels.
- `ChatTelemetry`: emits latency, reconnect, upload, playback, and failure metrics.

### Recommended Tools

- Local durable store: `drift` with SQLite.
- Network awareness: `connectivity_plus` plus app lifecycle hooks.
- Crash/performance telemetry: `sentry_flutter` or Firebase Crashlytics/Performance.
- Backend tracing: OpenTelemetry for NestJS gateway request and chat-operation spans.
- E2E testing: Patrol or Maestro for owner/vet simulator flows.
- Flutter integration tests: `integration_test` plus fake API/realtime adapters where practical.
- Media processing candidates: platform-native AVFoundation/MediaCodec compression first; evaluate package wrappers only after checking maintenance and iOS/Android output quality.

## Phase 0: Correctness Before Manual Testing

Status: implemented in the owner and vet chat screens, with reducer tests still pending.

Purpose: remove the highest-risk reliability defects before deep manual QA.

Implement:

- Attachment-safe message reconciliation: raw Postgres `messages` events must not overwrite hydrated Broadcast/REST messages that already contain attachments.
- Cursor catch-up after Realtime subscribe/reconnect using `GET /sessions/{sessionId}/messages?afterStreamOrder={lastSeen}`.
- Foreground/resume sync for owner and vet chat screens.
- Stream continuity guard: if a message arrives with a stream gap, schedule a cursor catch-up instead of trusting local order.
- Text send timeout and retry action matching the media retry behavior.
- Message reducer tests for attachment preservation, duplicate client keys, receipt merge, and out-of-order events.

Acceptance criteria:

- Attachment messages never flicker into empty media bubbles after Realtime events.
- Killing and reopening either app catches up all missed messages without duplicates.
- Toggling network during a send leaves a recoverable failed/queued message, not a lost message.

## Phase 1: Durable Outbox and Message State Machine

Status: first-pass implementation complete for owner and vet consult sends using a file-backed app-support outbox, plus file-backed consult draft restore. Retryable failures now persist structured error metadata, jittered next-retry timestamps, and bounded automatic retry scheduling; hard failures such as auth, closed sessions, unsupported media, and size limits remain manual/non-retryable. A future hardening pass should migrate this to `drift`.

Purpose: make sends resilient to app kills, poor network, duplicate taps, and route changes.

Implemented in first pass:

- Persist pending text/media sends before network calls.
- Flush outbox on app foreground, route/message load, cursor catch-up, and manual retry.
- Persist and restore unsent consult text drafts per session.
- Use stable local IDs and `clientKey` mapping to reconcile local pending messages with server messages.
- Store send attempt count, last error, and created/updated timestamps.
- Show owner and vet labels for sending, retrying, failed, delivered, and read states.

Remaining implementation work:

- Add local `drift` tables for chat messages, outbox entries, draft rows, attachment drafts, upload attempts, and sync cursors.
- Add richer retry classification using gateway response codes instead of client-side coarse error mapping.

Acceptance criteria:

- App kill during text send does not lose the message.
- App kill during media upload restores the selected media draft or failed upload state.
- Double-tapping send cannot create duplicate server messages.
- Owner and vet labels progress cleanly from sending to sent/delivered/read.

## Phase 2: Media Upload UX and Staging

Status: implementation complete for owner and vet composer staging, remove-before-send, local previews, pre-upload validation, visible ready/uploading state, native image/video compression before upload, real byte-level upload progress, upload cancellation, and failed-message retry. Remaining hardening work is video thumbnails and richer failed-media reasons.

Purpose: make media feel fast and controlled, especially on slow networks.

Implemented in first pass:

- Pre-send staging tray for selected images, selected video, and recorded voice notes.
- Remove-before-send for staged media.
- Client-side validation before signed URL creation: file type, size, duration, and visible error copy.
- Local previews for staged images and icon previews for staged video/voice.
- Per-attachment byte-level upload progress during signed media uploads.
- Cancel controls for in-flight uploads and inline retry actions for failed consult sends.
- Better pending media state inside the optimistic bubble while upload/send is in progress.
- Images are compressed to clinical-inspection-friendly JPEGs before upload when compression reduces size.
- Videos run through the platform video compressor before upload when compression reduces size, while preserving audio and falling back to the original file if compression fails.

Remaining implementation work:

- Generated thumbnails for local and remote videos.
- Better failed media state inside the bubble, including reason and retry.

Acceptance criteria:

- Slow video upload shows useful progress, not a frozen bubble.
- Users can remove an accidental attachment before sending.
- Oversized media fails early with clear copy before wasting upload time.
- Video thumbnails show before playback where possible.

## Phase 3: Realtime Reliability and Presence Polish

Status: first-pass implementation complete for owner and vet channel status handling, reconnect backoff, catch-up after resubscribe, stale typing expiry, typing stop events, and read receipt batching. Remaining work is extracting a typed Realtime wrapper and adding deeper reconnect telemetry/tests.

Purpose: make live chat robust when Realtime is imperfect.

Implemented in first pass:

- Channel status handling for subscribed, closed, errored, timed out, and reconnecting states.
- Reconnect backoff with cursor catch-up after every successful resubscribe.
- Stale typing expiry based on event timestamp, not only local timers.
- Typing stop event on send, blur, route exit, and app background.
- Receipt batching so visible-read updates do not hammer the gateway.

Remaining implementation work:

- Typed Realtime event wrapper for `messages`, `receipts`, `typing`, and presence events.
- Presence join/leave micro-events that do not spam the thread.

Acceptance criteria:

- Realtime disconnect does not permanently hide messages.
- Typing never stays stuck after a crash or background event.
- Presence reflects owner/vet online state without noisy repeated system messages.

## Phase 4: Observability and Operations

Status: first-pass implementation complete for durable chat telemetry intake, owner/vet client telemetry emission, sanitized correlation IDs, gateway OpenTelemetry API spans, admin chat reliability/media endpoints, and structured alert delivery hooks. Remaining hardening work is production SLO dashboards and exporter/paging configuration.

Purpose: make chat health measurable before users report issues.

Implemented in first pass:

- Added `chat_telemetry_events` storage with RLS and metadata comments forbidding message bodies/private storage paths.
- Added `POST /sessions/{sessionId}/telemetry` with rate limiting, participant access checks, sanitized metadata, and admin/audit rejection.
- Owner and vet clients now emit non-blocking telemetry for send started/completed/failed, upload started/progress/completed/failed, realtime reconnect, catch-up, playback signed URL refresh, and read receipt delay.
- Client telemetry correlates session, actor role, `clientKey`, message ID, attachment ID, durations, counts, and coarse error codes without sending message text or private paths.
- Added `GET /admin/ops/chat-reliability` with 24h send/upload/reconnect/catch-up/playback metrics, playback signed URL refresh failure rate, p95 first-vet-response latency, p95 latency summaries, stale pending upload checks, failure reason summaries, and alert flags.
- Added gateway OpenTelemetry API spans for message create/list/read, attachment upload-url creation, signed upload URL signing, attachment verification, signed download URL refresh, and private Broadcast emit.
- Added alert delivery wiring for chat reliability and media ops warnings/critical states: active alerts are emitted as structured gateway logs and optionally POSTed to `CHAT_OPS_ALERT_WEBHOOK_URL`/`OPS_ALERT_WEBHOOK_URL` with bearer-token support.

Remaining implementation work:

- Install/configure the production OpenTelemetry SDK/exporter and promote dashboard metrics into production SLOs and paging thresholds.

Acceptance criteria:

- A failed chat send can be traced from client attempt to gateway response.
- Admins can see if chat degradation is message delivery, Realtime, upload, or playback related.
- Logs do not include private message content unless explicitly intended for support/export flows.

## Phase 5: Accessibility and UX Finish

Status: first-pass implementation complete for owner and vet accessibility labels, screen-reader announcements, larger primary hit targets, haptics on record/send outcomes, upload cancel/retry semantics, draft restore banners, date separators, and unread markers. Remaining hardening work is widget-level accessibility tests and deeper dynamic-text QA.

Purpose: make the current UI usable, fast, and clear for all users.

Implemented in first pass:

- Owner and vet controls now expose semantic labels/tooltips for back, end consult, send, attach media, hold-to-record voice, remove staged media, and voice/video playback retry/play/pause.
- Owner survey/service action pills now behave as semantic buttons with selected/enabled state.
- Owner and vet chat screens announce new incoming messages, remote typing, presence entry/online changes, staged/removed attachments, upload failures, send failures, and voice recording state without reading clinical message bodies aloud.
- Composer media, mic, send, staged attachment remove, header, and playback controls now use larger 44px touch targets while preserving the existing visual shell.
- Owner and vet add haptic feedback for hold-to-record start/stop and send success/failure.
- Owner and vet upload overlays expose labeled cancel controls, and failed consult messages expose labeled retry actions.
- Owner and vet consults restore unsent text drafts with dismissible banners.
- Owner and vet consult threads show inline date separators and unread markers after catch-up.

Remaining implementation work:

- Dynamic text checks for all bubble metadata and buttons.
- Widget-level accessibility coverage for the new cancel/retry, draft, date, and unread states.

Acceptance criteria:

- VoiceOver/TalkBack users can send text, attach media, record voice, play media, retry failures, and read message state.
- Dynamic text does not break composer or bubble layout.
- A long consult remains scannable with dates and unread position.

## Phase 6: Testing System

Status: smoke-test first pass implemented for chat realtime/message reliability, admin media metrics, media processing worker trigger, and reliability dashboard metric shape. Formal Flutter reducer/widget/integration tests are still pending.

Purpose: catch delivery regressions before staging/manual testing.

Implemented in first pass:

- Existing `env/scripts/smoke-chat-consult-realtime.sh` covers assigned chat start, AI handoff load, owner/vet message send, duplicate `clientKey` idempotency, cursor sync, read receipts, survey eligibility, and admin chat consultation/media ops endpoints.
- Added `env/scripts/smoke-chat-media-processing.sh` to verify chat media ops, the processing jobs migration, dry-run and live worker trigger behavior, and the reliability dashboard fields for playback refresh failure rate and first-vet-response latency.

Implement:

- Flutter reducer unit tests for ordering, duplicate handling, receipts, attachment preservation, and local/server reconciliation.
- Flutter widget tests for message states, media bubbles, retry actions, typing status, and accessibility labels.
- Integration tests for owner/vet text chat, image upload, video upload/playback, voice upload/playback, signed URL refresh, read receipts, and reconnect catch-up.
- Bash or Node smoke tests for full attachment upload URL, signed upload access, message attach, list hydration, signed URL refresh, remove, and admin transcript export.
- Network chaos test plan: airplane mode, app background, app kill, slow network, duplicate taps, expired signed URL, large media, and closed session.

Acceptance criteria:

- CI or pre-release scripts catch the attachment-empty Realtime regression.
- CI catches duplicate message creation when `clientKey` is reused.
- Smoke tests verify at least one image, one video, and one voice attachment lifecycle.

## Phase 7: Media Intelligence Workers

Status: hardening implementation complete for a durable processing job queue, admin worker trigger, production scheduler, operational metrics, FFmpeg image/video thumbnail generation, FFmpeg server-side voice waveform extraction, ClamAV-compatible malware scanning integration, processing status broadcasts, optional OpenAI-compatible voice transcription, and transcript summarization into vet handoff context.

Purpose: make media clinically useful after delivery.

Implemented in first pass:

- Added `chat_media_processing_jobs` with RLS, per-attachment unique tasks, pending/running/succeeded/failed/skipped state, attempts, result metadata, and automatic enqueueing when attachments become ready.
- Added a gateway `ChatMediaProcessingService` that claims pending jobs, writes structured per-task processing metadata back onto `message_attachments`, generates image/video thumbnails with FFmpeg, extracts server-side voice waveforms with FFmpeg when no client waveform exists, validates coarse media safety constraints, runs a configured malware scanner, marks unsafe attachments failed, and transcribes voice notes through the configured OpenAI-compatible audio transcription endpoint when provider/storage credentials exist.
- Added opt-in scheduler controls (`CHAT_MEDIA_PROCESSING_ENABLED`, interval, batch size, stale timeout, and run-on-start) plus Render defaults and gateway image FFmpeg/ClamAV packages.
- Added `POST /admin/ops/chat-media/process` for dry-run and bounded worker execution, plus chat-media ops metrics/alerts for processing job table readiness, worker config, per-task latency, stale jobs, failed jobs, and failure reasons.
- Added private consult-room `attachment_processing` status broadcasts for ready/failed worker results without exposing signed URLs or storage paths.
- Voice note transcriptions now generate factual, non-diagnostic handoff summaries and merge them into `ai_handoffs.summary_text`/structured handoff fields, with a private `handoff_updated` broadcast for clients to refresh.
- Added smoke coverage for media processing readiness and trigger behavior.

Implement:

- Tune production scanner definitions and scheduler thresholds from live volume.

Acceptance criteria:

- Voice notes eventually show real waveform data.
- Vet handoff can include voice-note transcript context when available.
- Failed media processing does not block original message delivery.

## Manual Testing Matrix

Run after Phase 0 at minimum, and repeat after Phase 1 and Phase 2.

- Owner sends text, vet receives live, owner sees delivered/read.
- Vet sends text, owner receives live, vet sees delivered/read.
- Owner and vet send simultaneously; order stays stable by `stream_order`.
- Realtime disconnects; app catches up missed messages with `afterStreamOrder`.
- App killed during text send; message restores and sends or shows retry.
- App killed during media upload; media draft or failed upload state restores.
- Owner sends image/video/voice; vet receives hydrated attachments and can play/open.
- Vet sends image/video/voice; owner receives hydrated attachments and can play/open.
- Expired signed media URL refreshes before retrying playback.
- Large/unsupported media fails with clear copy.
- Session closed while typing/sending; UI stops retrying and explains why.
- VoiceOver/TalkBack can operate the full chat path.

## Go/No-Go For Chat V2.0

Go only when:

- No message loss under app kill, network loss, or Realtime reconnect.
- No duplicate server messages from double taps or retries.
- Attachment hydration survives raw Realtime and Broadcast ordering differences.
- Text and media sends have durable retry states.
- Upload progress/cancel/retry exists for slow media.
- Accessibility labels exist for every custom chat control.
- Chat reliability telemetry and gateway operation spans exist in both client and gateway.
- Automated tests cover reducer, reconnect, send retry, media lifecycle, and signed URL refresh.

## Recommended Implementation Order

1. Attachment-safe reducer and cursor catch-up.
2. Text send timeout/retry and formal message states.
3. Local `drift` outbox and draft persistence.
4. Reconnect manager and foreground/resume sync.
5. Media staging tray, upload progress, cancel, retry, and compression hooks.
6. Accessibility pass for all chat controls and live states.
7. Telemetry and admin reliability dashboard.
8. Reducer/widget/integration tests and media smoke tests.
9. Media intelligence workers for thumbnails, waveform, transcription, and safety scanning.