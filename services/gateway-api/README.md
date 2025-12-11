# Gateway API — Subscriptions, Sessions, Overage, Stripe

This document inventories all implemented endpoints, internal flows, data models, Stripe webhook handling, and idempotency. It also lists missing items and proposed spec updates to keep contracts aligned.

## API Groups
## Environment Variables — Storage
- `SUPABASE_URL`: Supabase Project URL (Project Settings → API → Project URL)
- `SUPABASE_SERVICE_ROLE_KEY`: Supabase service_role key (server-only; never expose to clients)
- `SUPABASE_STORAGE_BUCKET`: Storage bucket name (e.g., `files`)

Set these in your deployment (Render) under the gateway service. `render.yaml` declares the keys; fill the values in the dashboard.

### Files Flow
- Upload: `POST /files/upload` with body `{ path, content(base64), contentType?, petId?, sessionId?, labels?, findings?, diagnosis_label? }`
  - Uploads to Supabase Storage and, if `petId` is provided, inserts an `image_cases` row referencing `path`.
- Download: `GET /files/download-url?path=...` returns a signed URL (private bucket).
- Recommended path convention: `pets/{PET_ID}/cases/{filename}`.


- `subscriptions`: plans, lifecycle, overage, usage, entitlements
- `sessions`: chat/video session lifecycle, entitlement consumption
- `admin/pricing`: Stripe products/prices reconciliation
- `internal/stripe`: webhook ingestion (secret-guarded)

Status legend
- Real: implemented against Stripe/DB and used in staging
- Stub: local-only behavior (no Stripe); requires consolidation or removal
- Admin: management/ops; should be guarded by admin secret/role
- Needs work: endpoint exists but behavior incomplete/placeholder

## Subscriptions


- `POST /subscriptions/stripe/checkout` — Real
  - Creates Stripe Checkout Session for recurring plans.
  - Attaches `metadata.user_id`; webhook should upsert `user_subscriptions` and open `subscription_usage`.
  - Needs work: README + OpenAPI must reflect final payloads; ensure portal link and success/cancel URLs handled.
- `GET /subscriptions/debug-auth-tx`
  - Shows `auth.uid()` inside transaction + claims for diagnostics.
- `GET /subscriptions/debug-auth`
  - Returns decoded claims and `auth.uid()`.
- `GET /subscriptions/db-status`
  - DB connectivity probe.
- `GET /subscriptions/debug-active`
  - Compares active view vs underlying table for current user.
- `POST /subscriptions/portal`
  - Returns placeholder for Stripe customer portal (frontend to implement).
- `POST /subscriptions/overage/checkout` — Real
  - Creates one-off Stripe Checkout Session for overage items (units or session-bound).
  - Persists `overage_purchases` with `status='checkout_created'` (+ optional `original_session_id`).
  - Webhook should mark `paid` and then credit units or consume if session-bound.
- `POST /subscriptions/overage/consume` — Real
  - Manual consume: prefers a `paid` purchase link; else decrements credits.
  - Idempotent by checking for prior consumption for a given purchase.
- `GET /subscriptions/overage/items` — Real
  - Lists active overage catalog items (`chat_unit`, `video_unit`, `emergency_consult`, `sms_unit`).
- `GET /subscriptions/overage/credits` — Real
  - Lists remaining credit units per item for the current user.
- `POST /subscriptions/cancel` — Real
  - Cancels active subscription: immediate or at period end.
- `POST /subscriptions/resume` — Real
  - Resumes a scheduled cancellation.
- `POST /subscriptions/change-plan` — Real
  - Changes plan code and updates included usage counts without resetting consumed.
- `POST /subscriptions/reserve-chat` — Real (internal)
  - Calls `fn_reserve_chat(sessionId)` to reserve a chat entitlement.
- `POST /subscriptions/reserve-video` — Real (internal)
  - Calls `fn_reserve_video(sessionId)` to reserve a video entitlement.
- `POST /subscriptions/commit` — Real (internal)
  - Finalizes a pending consumption (`fn_commit_consumption`).
- `POST /subscriptions/release` — Real (internal)
  - Releases a pending consumption (`fn_release_consumption`).
- `GET /subscriptions/usage` — Real
  - Returns full usage from `fn_current_usage` for the active subscription.
- `GET /subscriptions/my` — Real
  - Lists user subscriptions with embedded plan details.
- `GET /subscriptions/usage/current` — Real
  - Minimal snapshot of current period usage.

### Overage Management (Admin)
- `GET /subscriptions/admin/overage/purchases` — Admin
  - Lists user overage purchases (code, status, quantity, totals, original_session_id).
- `GET /subscriptions/admin/overage/consumptions` — Admin
  - Lists consumptions with `source in ('overage','credit')`.
- `POST /subscriptions/admin/overage/mark-paid` — Admin
  - Marks purchase `paid`; session-bound optional `force_consume`, units credit increment.
- `POST /subscriptions/admin/overage/mark-refunded` — Admin
  - Marks purchase `refunded`; reverses credits if previously `paid` and unconsumed units.
- `POST /subscriptions/admin/overage/adjust-credits` — Admin
  - Grants/revokes credits by `delta` (+/-) for an item.
  - Requires header `x-admin-secret` matching `ADMIN_PRICING_SYNC_SECRET` env var (fallback: `ADMIN_SECRET`).
  
## Part 1 — API Groups: Routes + Current Status

Legend
- verified: implemented and tested against staging/dev stack
- pending: implemented but needs specific validation/spec alignment
- todo: not implemented

Health/Meta/Docs
- `GET /health` — verified
  - Basic health probe.
- `GET /version` — verified
  - Returns service version.
- `GET /time` — verified
  - Server time.
- `GET /openapi.yaml` — verified
  - Spec includes admin paths + session payment fields.
- `GET /docs` — verified
  - Static docs page.
- `GET /openapi-chat-ws.yaml` — pending
  - Chat WS spec present; needs review against implementation.
- `GET /openapi-webhooks.yaml` — pending
  - Webhooks spec present; needs review against handler payloads.
- `GET /docs/chat` — verified
- `GET /docs/webhooks` — verified
Internal Billing
- `GET /internal/billing/health` — verified
  - Internal billing health endpoint.

System DB
- `GET /_db/status` — verified
  - DB connectivity + stub status snapshot.

Internal Stripe
- `POST /internal/stripe/event` — pending
  - Idempotent (replay ok=true). Missing distinct `reason:"ignored_duplicate"` on replay.
- `POST /internal/stripe/ingest` — pending
  - Normalize Stripe event into DB (internal). Spec present; needs implementation/status check.

Subscriptions (User)
- `POST /subscriptions/stripe/checkout` — pending
  - Creates Stripe Checkout for plans. Needs spec validation and full E2E test.
- `POST /subscriptions/checkout` — pending
  - Legacy/alias path in spec; confirm implementation or deprecate.
- `GET /subscriptions/debug-auth-tx` — verified
  - Shows `auth.uid()` in transaction.
- `GET /subscriptions/debug-auth` — verified
  - Decoded claims + `auth.uid()`.
- `GET /subscriptions/db-status` — verified
  - DB connectivity.
- `GET /subscriptions/debug-active` — verified
  - Active subscription diagnostic.
- `POST /subscriptions/portal` — pending
  - Portal URL placeholder; frontend integration needed.
- `POST /subscriptions/overage/checkout` — pending
  - One-off Checkout for overage items; needs real Stripe E2E.
- `POST /subscriptions/overage/consume` — pending
  - Manual consume preferring purchase; idempotent via linkage. Needs duplicate-prevention assertion.
- `GET /subscriptions/overage/items` — verified
  - Active catalog items list.
- `GET /subscriptions/overage/credits` — verified
  - Remaining credits per item.
- `POST /subscriptions/cancel` — pending
  - Immediate or period-end cancel; needs spec validation.
- `POST /subscriptions/resume` — pending
  - Resume scheduled cancel; needs spec validation.
- `POST /subscriptions/change-plan` — pending
  - Change plan code/update usage; needs spec validation.
- `POST /subscriptions/reserve-chat` — pending
  - Calls `fn_reserve_chat`; needs targeted test.
- `POST /subscriptions/reserve-video` — pending
  - Calls `fn_reserve_video`; needs targeted test.
- `POST /subscriptions/commit` — pending
  - Finalize pending consumption; needs targeted test.
- `POST /subscriptions/release` — pending
  - Release pending consumption; needs targeted test.
- `GET /subscriptions/usage` — pending
  - Full usage snapshot; needs spec alignment.
- `GET /subscriptions/my` — pending
  - User subscriptions list; needs spec alignment.
- `GET /subscriptions/usage/current` — pending
  - Minimal current usage; needs spec alignment.

Subscriptions (Admin Overages)
- `GET /subscriptions/admin/overage/items` — verified
  - Guarded list; requires `x-admin-secret`.
- `POST /subscriptions/admin/overage/items` — verified
  - Guarded upsert; requires `x-admin-secret`.
- `POST /subscriptions/admin/overage/adjust-credits` — verified
  - Guarded; unified secret; tested.
- `GET /subscriptions/admin/overage/purchases` — verified
  - Guarded purchases list.
- `GET /subscriptions/admin/overage/consumptions` — verified
  - Guarded consumptions list.
- `POST /subscriptions/admin/overage/mark-paid` — pending
  - Guarded; needs test for units vs session-bound paths.
- `POST /subscriptions/admin/overage/mark-refunded` — pending
  - Guarded; needs refund reversal tests.

Plans
- `GET /plans` — pending
  - Plans list; needs spec/fields validation.
- `GET /plans/:code` — pending
  - Plan detail; needs spec/fields validation.

Entitlements
- `POST /entitlements/reserve` — pending
  - Reserve entitlement; needs test.
- `POST /entitlements/commit` — pending
  - Commit entitlement; needs test.
- `POST /entitlements/release` — pending
  - Release entitlement; needs test.

Admin Pricing
- `POST /admin/pricing/sync` — verified
  - Guarded pricing sync.

Sessions
- `GET /sessions` — pending
  - Sessions list; needs spec alignment.
- `GET /sessions/:sessionId` — pending
  - Session detail; needs spec alignment.
- `PATCH /sessions/:sessionId` — pending
  - Update session; needs spec alignment.
- `POST /sessions/start` — verified
  - If credits exhausted → `overage:true` with `payment.url` + `checkout_session_id`; concurrency PASS with 1 credit.
- `POST /sessions/end` — pending
  - Ends session; commits when `consumptionId` provided; needs validation.
Messages
- `GET /messages` — pending
  - List messages across sessions; controller present.
- `GET /messages/transcripts` — pending
  - List available transcripts; controller present.
- `GET /messages/:id` — pending
  - Message detail; controller present.

Centers
- `GET /centers/near` — pending
  - Nearby centers; needs spec alignment.
  - No other centers endpoints found in controllers.

Vector
- `POST /vector/search` — pending
  - Vector search; needs spec alignment.
- `GET /vector/search` — pending
  - Vector search (GET); needs spec alignment.
- `POST /vector/upsert` — pending
  - Upsert vectors; needs spec alignment.
- `GET /vector/debug` — pending
  - Debug info; needs spec alignment.
- `GET /vector/pets` — pending
  - Pets embeddings; needs spec alignment.

KB
- `GET /kb` — pending
  - Knowledge base list; needs spec alignment.
- `GET /kb/:id` — pending
  - KB item; needs spec alignment.
- `POST /kb` — pending
  - Create KB item; needs spec alignment.
- `PATCH /kb/:id/publish` — pending
  - Publish KB item; needs spec alignment.

Search
- `GET /search` — verified
  - Lexical KB search; controller present.
Payments & Invoices
- `GET /payments` — todo
  - Spec-only; no payments controller.
- `GET /payments/:paymentId` — todo
  - Spec-only; no payments controller.
- `POST /payments/one-off/checkout` — todo
  - Spec-only; no payments controller.
- `GET /invoices` — todo
  - Spec-only; no invoices controller.
- `GET /invoices/:invoiceId` — todo
  - Spec-only; no invoices controller.

Ratings & Feedback
- `POST /sessions/:sessionId/ratings` — todo
  - Spec-only; no ratings controller.
- `GET /vets/:vetId/ratings` — todo
  - Spec-only; no ratings controller.
- `GET /sessions/:sessionId/ratings` — todo
  - Spec-only; no ratings controller.

Notifications
- `POST /notifications/test` — todo
  - Spec-only; no notifications controller.
- `POST /notifications/receipt` — todo
  - Spec-only; no notifications controller.

Files & Storage
- `POST /files/signed-url` — todo
  - Spec-only; no files controller.
- `GET /files/download-url` — todo
  - Spec-only; no files controller.

Admin Ops
- `GET /admin/users` — todo
  - Spec-only; no admin users controller.
- `GET /admin/users/:userId` — todo
  - Spec-only; no admin users controller.
- `GET /admin/subscriptions` — todo
  - Spec-only; no admin subscriptions controller.
- `POST /admin/credits/grant` — todo
  - Spec-only; no admin credits controller.
- `POST /admin/refunds` — todo
  - Spec-only; no admin refunds controller.
- `POST /admin/vets/:vetId/approve` — todo
  - Spec-only; no admin vet approval controller.
- `POST /admin/plans` — todo
  - Spec-only; no admin plans controller.
- `POST /admin/coupons` — todo
  - Spec-only; no admin coupons controller.
- `GET /admin/analytics/usage` — todo
  - Spec-only; no admin analytics controller.
Pets
- `GET /pets` — verified
  - Present in runtime controller.
- `GET /pets/:petId` — verified
  - Present in runtime controller.
- `POST /pets` — todo
  - Spec-only; not in controllers.
- `PATCH /pets/:petId` — todo
  - Spec-only; not in controllers.
- `DELETE /pets/:petId` — todo
  - Spec-only; not in controllers.
- `POST /pets/:petId/files/signed-url` — todo
  - Spec-only; not in controllers.

Me
- `GET /me` — verified
  - Present in runtime controller.
- `PATCH /me` — verified
  - Present in runtime controller.
- `GET /me/security/sessions` — verified
  - Present in runtime controller.
- `POST /me/security/logout-all` — verified
  - Present in runtime controller.
- `POST /me/security/logout-all-supabase` — verified
  - Present in runtime controller.
- `GET /me/billing-profile` — verified
  - Present in runtime controller.
- `PUT /me/billing-profile` — verified
  - Present in runtime controller.
- `POST /me/billing/payment-method/attach` — verified
  - Present in runtime controller.
- `DELETE /me/billing/payment-method/:pmId` — verified
  - Present in runtime controller.

## Part 2 — Yet To Be Tested (Functions + Routes)
- Webhook duplicate reason — `POST /internal/stripe/event`: validate response returns `reason:"ignored_duplicate"` on replay.
- Real Stripe E2E — `POST /subscriptions/overage/checkout` + webhook: run real Checkout, assert purchases→consumed/refunded transitions.
- Reporting/rate-limiting — aggregate endpoints to be verified across `subscriptions/*` and admin listings.
- Observability tags — ensure route logs/metrics on `sessions/*`, `subscriptions/*`, `internal/stripe/event`.
  - Include `centers/*`, `payments/*`, `admin/*` where applicable.

## Part 3 — Yet To Be Done (Functions + Routes)
- Webhook replay reason: implement `ignored_duplicate` in handler — `POST /internal/stripe/event`.
- Reporting endpoints: add aggregates (periodic summaries) — likely under `/subscriptions/admin/overage/report*` (TBD).
- Rate limiting + alerts: apply limits to hot paths (`/sessions/start`, `/subscriptions/overage/*`) and wire observability alerts.

## Smoke Tests (How to Run)
```zsh
set -a && source ./.env.staging && set +a
export AUTH_HEADER="Authorization: Bearer $SB_ACCESS_TOKEN"

bash env/scripts/smoke-openapi-admin-overage.sh
zsh env/scripts/smoke-webhook-concurrency.sh
```