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

Known gap:

- The chat works, but it is still memory-first on the client. It needs a durable local outbox, reconnect catch-up, formal message state machine, upload progress, accessibility pass, and deep telemetry before it should be called world-class.

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

Purpose: make sends resilient to app kills, poor network, duplicate taps, and route changes.

Implement:

- Add local `drift` tables for chat messages, outbox entries, attachment drafts, upload attempts, and sync cursors.
- Persist drafts per session.
- Persist pending text/media sends before any network call.
- Flush outbox on network regain, app foreground, route entry, and manual retry.
- Use stable local IDs and `clientKey` mapping to reconcile local pending messages with server messages.
- Store send attempt count, next retry time, last error code, and created/updated timestamps.
- Add exponential retry with jitter for retryable failures.
- Do not retry non-retryable errors such as unauthorized, session closed, unsupported media type, or hard size limit.

Acceptance criteria:

- App kill during text send does not lose the message.
- App kill during media upload restores the selected media draft or failed upload state.
- Double-tapping send cannot create duplicate server messages.
- Owner and vet labels progress cleanly from sending to sent/delivered/read.

## Phase 2: Media Upload UX and Staging

Purpose: make media feel fast and controlled, especially on slow networks.

Implement:

- Pre-send staging tray for selected images, selected video, and recorded voice notes.
- Remove-before-send for staged media.
- Per-attachment upload progress where the upload layer supports progress callbacks.
- Cancel upload and retry upload actions.
- Client-side validation before signed URL creation: file type, size, duration, and visible error copy.
- Image compression before upload, preserving enough quality for clinical inspection.
- Video compression/transcoding path for large videos, using native platform encoders where possible.
- Generated thumbnails for local and remote videos.
- Better failed media state inside the bubble, including reason and retry.

Acceptance criteria:

- Slow video upload shows useful progress, not a frozen bubble.
- Users can remove an accidental attachment before sending.
- Oversized media fails early with clear copy before wasting upload time.
- Video thumbnails show before playback where possible.

## Phase 3: Realtime Reliability and Presence Polish

Purpose: make live chat robust when Realtime is imperfect.

Implement:

- Typed Realtime event wrapper for `messages`, `receipts`, `typing`, and presence events.
- Channel status handling for subscribed, closed, errored, timed out, and reconnecting states.
- Reconnect backoff with cursor catch-up after every successful resubscribe.
- Presence join/leave micro-events that do not spam the thread.
- Stale typing expiry based on event timestamp, not only local timers.
- Typing stop event on send, blur, route exit, and app background.
- Receipt batching so visible-read updates do not hammer the gateway.

Acceptance criteria:

- Realtime disconnect does not permanently hide messages.
- Typing never stays stuck after a crash or background event.
- Presence reflects owner/vet online state without noisy repeated system messages.

## Phase 4: Observability and Operations

Purpose: make chat health measurable before users report issues.

Implement:

- Gateway OpenTelemetry spans for message create/list/read, attachment upload-url, attachment verify, signed URL refresh, and Broadcast emit.
- Client telemetry for send latency, ack latency, realtime reconnect count, catch-up count, upload duration, upload failure reason, playback refresh attempts, and read receipt delay.
- Correlate `clientKey`, message ID, session ID, and actor role in logs without leaking message body or private storage paths.
- Admin chat reliability dashboard: send failure rate, p95 send latency, p95 first vet response, reconnect recovery count, upload failure rate, stale pending uploads, signed URL refresh failure rate.
- Alert thresholds for elevated create failures, realtime catch-up spikes, attachment verification failures, and orphaned uploads.

Acceptance criteria:

- A failed chat send can be traced from client attempt to gateway response.
- Admins can see if chat degradation is message delivery, Realtime, upload, or playback related.
- Logs do not include private message content unless explicitly intended for support/export flows.

## Phase 5: Accessibility and UX Finish

Purpose: make the current UI usable, fast, and clear for all users.

Implement:

- `Semantics` labels for send, attach, mic hold, cancel upload, retry, play/pause voice, play/pause video, end consult, and survey actions.
- Screen-reader announcements for new incoming message, typing state, upload failed, send failed, and vet entered chat.
- Larger hit targets for media, mic, retry, and playback controls while preserving the current look.
- Dynamic text checks for all bubble metadata and buttons.
- Haptic feedback for hold-to-record start/stop and send success/failure where appropriate.
- Unsent draft restore banner when returning to a consult.
- Inline date separators and unread marker for long consults.

Acceptance criteria:

- VoiceOver/TalkBack users can send text, attach media, record voice, play media, retry failures, and read message state.
- Dynamic text does not break composer or bubble layout.
- A long consult remains scannable with dates and unread position.

## Phase 6: Testing System

Purpose: catch delivery regressions before staging/manual testing.

Implement:

- Flutter reducer unit tests for ordering, duplicate handling, receipts, attachment preservation, and local/server reconciliation.
- Flutter widget tests for message states, media bubbles, retry actions, typing status, and accessibility labels.
- Integration tests for owner/vet text chat, image upload, video upload/playback, voice upload/playback, signed URL refresh, read receipts, and reconnect catch-up.
- Bash or Node smoke tests for attachment upload URL, signed upload access, message attach, list hydration, signed URL refresh, remove, and admin transcript export.
- Network chaos test plan: airplane mode, app background, app kill, slow network, duplicate taps, expired signed URL, large media, and closed session.

Acceptance criteria:

- CI or pre-release scripts catch the attachment-empty Realtime regression.
- CI catches duplicate message creation when `clientKey` is reused.
- Smoke tests verify at least one image, one video, and one voice attachment lifecycle.

## Phase 7: Media Intelligence Workers

Purpose: make media clinically useful after delivery.

Implement:

- Image and video thumbnail generation worker.
- Voice waveform extraction from real audio.
- Voice transcription worker with status updates.
- Optional AI summarization of transcribed voice notes into vet handoff context.
- Malware/content safety scan for uploaded media before exposing it broadly.
- Attachment processing status events for ready/failed worker results.

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
- Chat reliability telemetry exists in both client and gateway.
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