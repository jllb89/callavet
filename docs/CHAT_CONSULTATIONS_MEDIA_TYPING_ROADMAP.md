# Chat Consultation Media, Typing, and Read-State Roadmap

## Goal

Add production-ready media attachments to chat consultations and polish live conversation state so both owner and vet can send images, videos, and voice notes, see when the other side is typing, and see a clear `Read` mark instead of role labels where that is the expected message-log behavior.

## Implementation Status

- Done: Phase 1 backend/spec/schema attachment contract is implemented.
- Done: Phase 2 launch storage plumbing is implemented and pushed: private `chat-media` bucket metadata, server-generated signed upload URLs, hard limit validation, uploaded object-size verification before attaching to a message, voice-note transcription status metadata, and private signed download URLs in message payloads.
- Done: Phase 3 launch composer/send pass is implemented in both Flutter apps: the existing chat composer includes the shared image/video icon, image gallery picker, video picker, hold-to-record mic control with white pressed state, session-scoped signed upload, attachment message creation, inline image rendering, and compact video/voice attachment bubbles without changing the current chat shell.
- Done: Phase 4 launch typing/read pass is implemented in both Flutter apps: existing private Broadcast typing remains in place and sender-side consult metadata now uses local time plus `Delivered`/`Read` instead of the dominant `tú` label, while received messages keep participant name plus local time.
- Done: Phase 5 inline voice note playback is implemented in both Flutter apps: voice bubbles now play inside the chat with play/pause, waveform-style progress bars, duration text, loading/error states, replay behavior, and one active voice note at a time per chat screen.
- Done: Phase 6 safety/admin observability is implemented: attachment lifecycle audit logs, admin chat media metrics, admin-safe transcript export with signed attachment links, and admin cleanup for orphaned pending uploads.
- Done: Phase 7 app media hardening is implemented for the shipped chat path: native in-chat video playback, one active video at a time, signed media URL refresh before retrying stale voice/video playback, failed-upload retry actions, owner stuck-optimistic cleanup, and admin media smoke coverage.
- Remaining future work: thumbnail/transcode/transcription workers, waveform generation from stored metadata, removable pre-send staging trays, explicit per-byte upload progress bars, and client-side video compression/transcoding.

## Next Pass: Phase 1-4 Completion Gate

The next implementation pass must make Phases 1-4 genuinely complete, with no launch-only caveats hidden inside those phases. Anything already added to Phase 1-4 must either be fully implemented and validated in that pass or explicitly moved to Phase 5+ before the pass is considered done.

### Must Finish or Verify

- Phase 1 contract: verify backend behavior, OpenAPI schemas, websocket message schema, and documented error codes match the shipped API exactly.
- Phase 1 message hydration: verify list, create, realtime/broadcast, and optimistic replacement paths all include `attachments: []` or populated attachment arrays consistently.
- Phase 2 storage: verify migration `0069_chat_message_attachments` is applied, private bucket metadata exists, RLS works for owner/vet/admin, pending upload verification works, and signed download URLs are returned for hydrated attachments.
- Phase 2 limits: verify images, videos, and voice notes hit the intended hard-limit errors consistently on server validation.
- Phase 2 processing scope: verify Phase 2 only owns storage metadata and processing placeholders; thumbnail, waveform, transcription, and video transcode workers must be assigned to Phase 7 unless they are fully implemented in the next pass.
- Phase 3 owner UI: verify text-only messages remain unchanged, image upload/render works, video upload/render/open works, voice record/upload/render works, media icon placement stays inside the current composer, and the mic pressed state is correct.
- Phase 3 vet UI: verify the same owner UI checklist in the vet app, including the registered shared `image-video.svg` asset and iOS photo-library permission.
- Phase 3 attachment UX: either implement retry/remove/progress inside Phase 3 or move those items formally to Phase 6/7 so Phase 3 has no unfinished bullet.
- Phase 4 typing/read: verify typing timeout behavior on both apps, read/delivered receipt broadcast after attachment messages, local-time labels, and sender-side `Delivered`/`Read` copy.
- Phase 4 locale copy: either implement Spanish/English locale-ready receipt copy or move it formally to a localization phase so Phase 4 has no unfinished bullet.
- Validation: run focused Flutter analyze for owner/vet chat files, gateway build, OpenAPI/editor diagnostics for touched specs, attachment smoke checks where available, and `git diff --check`.

### Phase 1-4 Done Means

- No `Partial`, `Deferred`, or `launch-only` language remains inside Phases 1-4.
- Any remaining future work is clearly assigned to Phase 5+.
- Owner and vet can send and receive text, images, videos, and voice notes through the production attachment contract.
- Receipts and typing still work after attachment messages.
- Roadmap status, validation checklist, and implementation order agree with the codebase state.

## Current State Audit

### Backend

- `POST /sessions/{sessionId}/messages` supports text messages through `content`/`clientKey` and can attach pending media records created by the upload-url endpoint.
- Messages are persisted in `public.messages` with `client_key`, global `stream_order`, `created_at`, edit/delete/redaction fields, and RLS-gated access through session participants.
- `POST /sessions/{sessionId}/messages/read` writes `public.message_receipts` and private Broadcast emits `receipts` on `consult-room:{sessionId}`.
- Typing is already transported through private Realtime Broadcast on `consult-room:{sessionId}` from both owner and vet apps.
- `POST /sessions/{sessionId}/attachments/upload-url` creates pending chat attachments and returns a signed private upload URL.
- `GET /sessions/{sessionId}/attachments/{attachmentId}/download-url` refreshes a ready attachment's signed download URL for the owner/vet participant when playback hits an expired URL.
- `POST /sessions/{sessionId}/attachments/{attachmentId}/remove` soft-removes sender/admin attachments for cleanup and recovery surfaces.
- `GET /admin/ops/chat-media` exposes attachment counts, byte totals, failed/pending/removed counts, media type distribution, and orphaned pending upload alerts.
- `POST /admin/ops/chat-media/cleanup-pending` marks orphaned pending uploads older than a configurable threshold as failed.
- `GET /admin/export/chat-transcripts/{sessionId}` returns admin-safe transcripts with attachment metadata and one-hour signed download links for ready media.
- Generic `POST /files/upload` still exists for server-side base64 upload and `GET /files/download-url` exists for general signed downloads, but chat media uses the session-scoped attachment contract.
- `encounter_files` exists for clinical encounter artifacts, but it requires an encounter and does not model message-level attachments.

### Schema

- `public.messages` remains the ordered message record; attachment metadata now lives in `public.message_attachments`.
- `public.message_receipts` is sufficient for delivered/read state, but clients currently derive copy locally.
- `public.message_attachments` stores multiple-image support, private storage paths, byte size, dimensions, duration, waveform, thumbnail placeholder, transcript fields, processing status, and metadata.
- Chat-specific storage pathing is `chat-consults/{sessionId}/{attachmentId}.{ext}` in the private `chat-media` bucket.

### API Spec

- `docs/openapi/openapi.yaml` now documents `MessageCreate` with `content`, `clientKey`, and `attachments`, plus `POST /sessions/{sessionId}/attachments/upload-url`.
- `docs/openapi/openapi.yaml` now also documents chat attachment download URL refresh, attachment remove, admin chat transcript export, admin chat media metrics, and admin pending-upload cleanup.
- `Message` schema now includes stream ordering and attachment metadata.
- `docs/openapi/openapi-chat-ws.yaml` now allows message events to carry attachment payloads.

### Owner App

- Owner chat already sends and receives consult text messages inline.
- Owner app shows vet typing in the top status line and receives read receipts.
- Owner chat can send up to 6 picked images, one picked video, or one hold-to-record voice note through the session-scoped attachment API.
- Owner chat renders attached images inline and renders compact video/voice attachment bubbles with media labels and voice duration when present.
- Owner chat plays attached videos inline with native controls, progress, duration, loading/error/retry state, and local optimistic video playback while upload is pending.
- Owner voice note recipient experience now plays inline inside the chat with a play/pause button, waveform-style progress rail, duration text, loading/error state, and replay behavior.
- Owner voice/video bubbles refresh signed media URLs automatically and retry playback when a stale URL fails.
- Owner failed media sends remove the stuck optimistic bubble and offer a one-tap retry using the same text/local files.
- Owner message metadata now shows local time with `Delivered`/`Read`; received vet messages keep vet name plus local time.
- Existing horse KYC upload flow has client-side media picking/upload examples, but it is not reusable for chat attachments yet.

### Vet App

- Vet chat already sends and receives consult text messages, receives owner typing, and applies read receipts.
- Vet chat can send picked images, picked video, and hold-to-record voice notes through the same session-scoped attachment API.
- Vet chat uses the same shared image/video SVG control inside the existing composer; the asset is registered in the vet app bundle.
- Vet chat renders attached images inline and renders compact video/voice attachment bubbles with media labels and voice duration when present.
- Vet chat plays attached videos inline with native controls, progress, duration, loading/error/retry state, and one active video at a time.
- Vet voice note recipient experience now plays inline inside the chat with a play/pause button, waveform-style progress rail, duration text, loading/error state, and replay behavior.
- Vet voice/video bubbles refresh signed media URLs automatically and retry playback when a stale URL fails.
- Vet failed media sends offer a one-tap retry using the same text/local files.
- Vet message metadata now shows local time with `Delivered`/`Read`; received owner messages keep owner display name plus local time.

## Voice Note Playback Status

Implemented behavior:

- Senders can press and hold the mic in the composer to record a voice note.
- The mic button is inside the existing chat input and turns into a white circular pressed state while recording.
- The sent voice note is uploaded as `kind: voice`, attached to the message, and delivered through the same message sync/realtime contract as text and image/video messages.
- Recipients see a compact Instagram-style voice attachment bubble with play/pause, deterministic waveform-style bars, progress fill, and duration text.
- Playback uses `just_audio` in-app instead of opening the signed audio URL externally.
- Only one voice note plays at a time per chat screen; starting another note pauses the currently playing note.
- Playback supports loading, failed/retry, completed/replay, and local optimistic voice-file playback for the sender while the final message is being hydrated.

Remaining future work:

- Refresh expired signed URLs automatically before playback if the message has gone stale. Implemented for current owner/vet voice and video bubbles through the session-scoped attachment refresh endpoint.
- Replace deterministic placeholder bars with stored waveform metadata when the worker exists.
- Native video playback is now in-app; external signed video URL opening is no longer the default chat behavior.

## Product Decisions

- Message attachments must be user/vet supplied media only; clinical summary/brief content remains AI-generated from the conversation and explicit context, not preset canned answers.
- Chat media should support images, videos, and voice notes in both directions.
- Oversized media should be compressed client-side when practical before upload, then rejected server-side if still over the hard limit.
- The UI should preserve fast text messaging while media uploads are in progress: a message can show pending attachment state, retry, or failed state without blocking the thread.
- Read state copy should be role-neutral for the sender: show `Read`/`Delivered` under sent messages instead of making `tú` the primary label.

## Proposed Limits

- Images: target client-compressed JPEG/WebP under 3 MB, hard server limit 8 MB.
- Videos: target compressed/transcoded under 25 MB, hard server limit 50 MB for launch.
- Voice notes: target AAC/M4A under 10 MB or 5 minutes, hard server limit 15 MB.
- Per message: up to 6 images, 1 video, or 1 voice note for launch.
- Upload timeout: 60 seconds per file with resumable upload as a phase 2 enhancement.

## Target Data Model

Add `public.message_attachments`:

- `id uuid primary key`
- `message_id uuid references public.messages(id) on delete cascade`
- `session_id uuid references public.chat_sessions(id) on delete cascade`
- `uploaded_by uuid references public.users(id) on delete set null`
- `kind text check in ('image','video','voice')`
- `storage_bucket text not null`
- `storage_path text not null`
- `content_type text not null`
- `byte_size bigint not null`
- `width int null`
- `height int null`
- `duration_ms int null`
- `thumbnail_path text null`
- `waveform jsonb null`
- `status text not null default 'pending' check in ('pending','ready','failed','removed')`
- `transcript_text text null`
- `transcript_status text default 'not_requested' check in ('not_requested','pending','ready','failed')`
- `deleted_at timestamptz null`
- `deleted_by uuid null`
- `metadata jsonb not null default '{}'::jsonb`
- `created_at timestamptz not null default now()`

Indexes:

- `(session_id, created_at desc)`
- `(message_id)`
- unique `(storage_bucket, storage_path)`

RLS:

- Select allowed to owner, assigned vet, and admin for the parent session.
- Insert allowed only to owner or assigned vet for the parent session.
- Update limited to uploader/admin for pending/failed metadata and to service role for scan/transcode status.

## API Roadmap

### Phase 1: Attachment Contract

- Update OpenAPI `MessageCreate` to accept `content`, `clientKey`, and optional `attachments` metadata references.
- Add `POST /sessions/{sessionId}/attachments/upload-url` for signed upload URL creation with `kind`, `contentType`, `byteSize`, `fileName`, and optional media metadata.
- Add `POST /sessions/{sessionId}/messages` support for creating a message with attachment references after upload succeeds.
- Extend list/sync responses so every message includes `attachments: []`.
- Add response errors: `attachment_too_large`, `unsupported_media_type`, `attachment_not_owned`, `attachment_not_ready`, `too_many_attachments`.

### Phase 2: Storage and Processing

- Create a private chat media bucket or path namespace: `chat-consults/{sessionId}/{messageId-or-uploadId}/...`.
- Generate signed upload URLs server-side; never expose service role credentials to clients.
- Validate MIME type, extension, declared byte size, and actual object size after upload.
- Store thumbnail, waveform, transcript, and processing-status metadata fields for later workers.
- Store voice note `duration_ms` from client capture where available.
- Thumbnail generation, waveform generation, voice transcription, and video transcoding are Phase 7 unless fully implemented in the next pass.

### Phase 3: Owner and Vet UI

- Implemented launch composer attachment controls in both apps: image/video picker button and hold-to-record voice note button inside the existing chat input.
- Implemented session-scoped signed upload and message creation for owner/vet images, videos, and voice notes.
- Implemented attachment rendering in both apps: inline image previews plus compact video/voice bubbles.
- Preserved text-only behavior when no attachment is present.
- Next pass decision: Phase 3 should mean basic send/receive/render media in both apps. If we keep that definition, Phase 3 is done after verification. Upload progress bars, retry buttons, remove-before-send controls, and richer playback should stay in Phase 7, not Phase 3.

### Phase 4: Typing and Read-State Polish

- Existing private Broadcast typing events remain active for owner and vet with the current timeout behavior.
- Replaced sender-side `tú`-dominant labels with `Delivered`/`Read` plus local time where useful.
- For received messages, participant display name plus local time is preserved.
- Next pass decision: Phase 4 should mean typing still works and sent-message receipt labels show local time plus `Delivered`/`Read`. If we keep that definition, Phase 4 is done after verification. Full Spanish/English localization and attachment-specific smoke tests should move to later localization/test coverage, not block Phase 4.

### Phase 5: Instagram-Style Voice Note Playback

- Implemented inline voice note bubbles in owner and vet apps with play/pause, waveform-style progress rail, and duration text.
- Implemented real in-app audio playback with `just_audio` instead of opening signed audio URLs externally for voice notes.
- Implemented one active voice note at a time per chat screen.
- Implemented loading, failed/retry, completed/replay, and local optimistic playback states.
- Preserved the existing hold-to-record composer behavior.
- Signed URL refresh on expiry remains Phase 7 media hardening unless implemented sooner with a dedicated attachment refresh endpoint.

### Phase 6: Safety, Observability, and Admin

- Implemented audit logs for upload URL creation/failure, message creation with attachments/failure, signed URL refresh, and sender/admin attachment removal.
- Implemented admin media metrics: total count, 24-hour creation count, pending/ready/failed/removed counts, total bytes, average upload size, media type distribution, and orphaned pending upload count.
- Implemented admin-safe transcript export with attachment metadata and one-hour signed download links for ready media.
- Implemented admin cleanup endpoint for orphaned pending uploads older than a configurable threshold, defaulting to 24 hours and dry-run mode.

### Phase 7: Native Video, Upload Polish, and Media Workers

- Implemented native in-chat video playback in owner and vet chat instead of opening signed video URLs externally.
- Implemented one active video at a time per chat screen, with play/pause, loading/error/retry state, progress rail, and duration text.
- Implemented signed media URL refresh before retrying voice/video playback when a signed URL has expired.
- Implemented failed-upload retry actions and owner optimistic-message cleanup so failed media sends do not leave dead pending bubbles in the thread.
- Implemented smoke-script coverage for the admin chat media metrics endpoint.

### Phase 8: Media Processing and Staging Enhancements

- Add removable pre-send staging trays for selected images/videos/voice notes before upload starts.
- Add explicit per-byte upload progress bars when the client upload layer supports progress callbacks.
- Add client-side compression/transcoding where practical before server hard-limit validation.
- Add thumbnail generation for images/videos and waveform/transcription workers for voice notes.
- Add full signed-upload attachment smoke tests for media delivery, receipts, signed URL access, and sender/admin removal.

## Implementation Order

1. Schema migration for `message_attachments`, RLS, indexes, and optional storage bucket policy notes.
2. Gateway upload-url endpoint and attachment validation service.
3. Extend message create/list/read responses and OpenAPI specs.
4. Owner app media picker/compressor/uploader and attachment bubble renderer.
5. Vet app media picker/compressor/uploader and attachment bubble renderer.
6. Voice note recorder for both apps.
7. Read-label copy pass and typing UI parity.
8. Instagram-style voice note playback for both apps.
9. Native video playback, signed URL refresh, upload retry, smoke tests, and admin observability.

Steps 4, 5, 6, 7, 8, and 9 are implemented for the shipped chat path. Compression/transcoding, removable pre-send staging trays, explicit upload progress bars, media processing workers, and full signed-upload smoke coverage remain Phase 8 work.

## Validation Checklist

- Owner sends text-only message: unchanged behavior.
- Vet sends text-only message: unchanged behavior.
- Owner sends image under target size: uploads, message appears live, vet can open it.
- Vet sends image under target size: uploads, message appears live, owner can open it.
- Owner sends voice note: uploads, message appears live, vet sees a voice bubble.
- Vet sends voice note: uploads, message appears live, owner sees a voice bubble.
- Voice note inline playback: plays/pauses inside the chat with progress UI, duration, replay, loading, and failed/retry state.
- Oversized image/video/voice note: server rejects over hard limits; client compression remains Phase 8.
- Network failure during upload: sender gets a retry action; owner stuck optimistic media bubbles are removed before retry.
- Message with attachment receives delivered/read receipts normally.
- Typing state clears after timeout on both apps.
- Sender-side label shows `Read`/`Delivered`, not `tú`, when receipt state exists.
- Admin transcript includes signed download links only behind the admin secret and does not expose unsigned private storage access to unauthorized users.

## Resolved Decisions

- Final launch limits are accepted as proposed: images hard limit 8 MB, videos hard limit 50 MB, voice notes hard limit 15 MB and 5 minutes.
- Phase 1 supports multiple images per message, capped at 6 images. Video and voice note messages launch with one attachment per message.
- Voice notes should be transcribed by AI for future handoff and notes context. Phase 1/2 stores `transcript_status`; the transcription worker belongs in a later implementation phase.
- Attachment deletion is sender-only, with admin retained for compliance/support operations.