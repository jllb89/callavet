# Pre-Redeploy Auth, Vet Dashboard, and Realtime Roadmap

This roadmap captures the UX and operational fixes to land before the next staging redeploy. The guiding rule is: the gateway and database remain the source of truth; Supabase Realtime makes the apps reflect that truth immediately.

## 1. Auth UX Unification

Status: Ready locally. Implemented before redeploy and validated with focused Flutter analysis.

Goal: one phone-first entry flow for both existing and new owners.

- [x] Keep the splash CTAs clear: `comenzar` for onboarding and `ingresar` for returning users.
- [x] Route onboarding completion and skip actions into the same phone OTP screen, not directly into KYC.
- [x] Send phone OTP with user creation enabled so unknown phone numbers can still receive a code.
- After OTP verification, inspect the `public.users` profile row:
  - complete existing profile: continue to subscription/home routing;
  - missing or incomplete profile: continue to the existing KYC/profile flow;
  - missing horse/subscription: continue through the existing post-login routing decisions.
- [x] Use neutral copy such as `continuar`, avoiding separate “sign in” and “sign up” language in the primary phone path.
- [x] Keep email as a recovery/fallback path, not as a second primary auth concept.

## 2. Active Consult Cleanup

Status: Backend cleanup ready locally. Queue filtering and the vet/admin manual end endpoint are implemented; the visible `...` menu belongs to the next dashboard UI point.

Goal: old sessions must never remain joinable as active consults.

- [x] Update `/vets/me/queue` so active video rows are filtered against `video_session_lifecycle` and sensible age limits.
- [x] Hide rows when the LiveKit room is finished, everyone has left, or the session is past the allowed active window.
- [x] Add a vet/admin endpoint to manually end an active consult.
- [x] When ending manually, update `chat_sessions`, related appointments, and `video_session_lifecycle` in one backend-owned operation.
- [x] Reuse LiveKit room termination for active video rooms where possible.
- [x] Keep reconciliation as the fallback sweeper for stale waiting/live sessions.

Suggested timeout policy:

- Waiting room with no full owner-vet join after 20 minutes: mark timed out and release any unfinalized entitlement.
- Room where all participants left for 5 minutes: mark ended/completed.
- Any active consult older than 2 hours: force close with an audit reason.

## 3. Vet Dashboard Rows and Manual Actions

Status: Ready locally. The vet home now renders one active event per row with service badges, data-backed status/mode/lifecycle/specialty/priority tags, video/chat primary actions, and a `...` menu wired to manual consult ending.

Goal: one event per row with clear service type and status.

- [x] Replace the current horizontal active-consult pill group with a vertical event list.
- [x] Render every active consult, not only the first item.
- [x] Each row should include:
  - leading icon badge for video or chat;
  - owner/patient label;
  - compact started/scheduled time;
  - tags such as `activa`, `video`, `chat`, `emergencia`, and specialty;
  - primary action to enter/open;
  - trailing `...` options menu with `finalizar consulta`.
- [x] On manual end, confirm, call the gateway endpoint, optimistically remove the row, then refetch the queue.
- [x] Persist session routing metadata (`specialty_id`, `priority`) and expose it through `/vets/me/queue` so tags such as `emergencia` and specialty are source-of-truth values.
- [x] Add a vet chat route/screen and wire chat rows to an `abrir` action.

## 4. Live Vet Dashboard With Supabase Realtime

Status: Phase A and Phase B ready locally and applied to staging. The vet app subscribes to Postgres Changes as a fallback, joins a private `vet-dashboard:{vetId}` Broadcast channel for precise dashboard events, debounces events, refetches `/vets/me/queue`, cleans up channels on dispose, and refreshes on app resume.

Goal: the vet home screen should behave like an operational live dashboard even before push notifications are enabled.

Phase A: Postgres Changes as a refetch trigger.

- [x] Initial state still comes from `/vets/me/queue`.
- [x] Subscribe to changes for `chat_sessions`, `appointments`, `video_session_lifecycle`, and session-scoped `messages` where the active chat screen needs live updates.
- [x] On a relevant insert/update/delete, debounce and refetch `/vets/me/queue`.
- [x] Remove Realtime channels on widget dispose and refetch on app resume.

Phase B: Private Broadcast for scale and precision.

- [x] Add database triggers that publish tiny events to `vet-dashboard:{vetId}`.
- [x] Use private channels with RLS policies on `realtime.messages`.
- [x] Keep payloads small, for example `{ "type": "vet_dashboard", "action": "insert", "sessionId": "..." }`.
- [x] The vet app receives the event and refetches the queue from the gateway.
- [x] Add a `realtime.messages` partition guard so database Broadcast inserts do not fail when daily partitions are missing.

Realtime constraints from the docs:

- Tables must be added to the `supabase_realtime` publication before Postgres Changes work.
- Postgres Changes are simple but every event must be authorized per subscriber under RLS, so they can bottleneck as usage grows.
- Broadcast is the recommended scalable path for database change notifications.
- Private Broadcast and Presence require RLS policies on `realtime.messages` and `private: true` client channels.
- Delete events are not filterable, so status updates are safer than relying on deletes.
- Flutter clients must unsubscribe/remove channels to avoid degrading Realtime performance.

## 5. Recommended Pre-Redeploy Order

1. [x] Auth UX unification.
2. [x] Backend queue correctness and stale active-consult filtering.
3. [x] Manual end endpoint and vet UI menu action.
4. [x] One-event-per-row dashboard UI.
5. [x] Realtime MVP using subscriptions as queue-refetch triggers.
6. [x] Broadcast-based dashboard events once the basic live dashboard is stable.
7. [x] Vet-side chat route and row-level open-chat action.
