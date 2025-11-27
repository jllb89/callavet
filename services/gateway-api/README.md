# Gateway API — Subscriptions, Sessions, Overage, Stripe

This document inventories all implemented endpoints, internal flows, data models, Stripe webhook handling, and idempotency. It also lists missing items and proposed spec updates to keep contracts aligned.

## API Groups

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

## Plans (Public)

- `GET /plans`
  - Lists active subscription plans with pricing and entitlements.
- `GET /plans/:code`
  - Returns plan details by code.

## Entitlements

- `POST /entitlements/reserve`
  - Reserves entitlement (`fn_reserve_chat|video`).
- `POST /entitlements/commit`
  - Commits a consumption.
- `POST /entitlements/release`
  - Releases a consumption.

## Sessions

- `GET /sessions`
  - Lists sessions for the authenticated user or vet.
- `GET /sessions/:sessionId`
  - Returns session details with ownership validation.
- `PATCH /sessions/:sessionId`
  - Updates status; sets `ended_at` when terminal (completed/canceled).
- `POST /sessions/start` — Real
  - Creates a session, reserves entitlement via `fn_reserve_*`.
  - Auto-credit draw when exhausted: decrement credits and insert `consumption` `source='credit'`.
  - On overage with no credits: initiates one-off Stripe Checkout bound to `original_session_id` and returns `payment.url` for completion (consolidated; no stub).
- `POST /sessions/end`
  - Marks session ended; commits `consumptionId` if provided.

## Admin Pricing

- `POST /admin/pricing/sync`
  - Admin-only endpoint guarded by `x-admin-secret` using `ADMIN_PRICING_SYNC_SECRET`.

## Internal Stripe Webhooks

- `POST /internal/stripe/event` — Real
  - Secret-guarded ingestion. Records idempotency in `stripe_subscription_events` and dispatches handlers.

### Handled Events

- `customer.subscription.created|updated|deleted`
  - Upserts `user_subscriptions` with status mapping, period start/end, cancel flags.
  - Resolves plan via `subscription_plan_prices` (fallback legacy columns).
- `invoice.payment_succeeded|invoice.payment_failed`
  - Updates `user_subscriptions.status` to `active|past_due`.
- `checkout.session.completed`
  - Marks `overage_purchases` `paid`.
  - Session-bound: auto-consume and set `consumed`.
  - Units-based: increment credits and set `credited`.
- `payment_intent.succeeded`
  - Same side-effects as above for purchases keyed by `stripe_payment_intent_id`.
- `payment_intent.payment_failed`
  - Marks `overage_purchases` `failed`.
- `charge.refunded|charge.refund.updated`
  - Marks `overage_purchases` `refunded`.
  - Reverses credits if previously `credited`; optional compensating credit for consumed based on policy.

### Customer Linkage

- Persists `stripe_customers(user_id, stripe_customer_id)` when `customer` is available.

### Idempotency

- `stripe_subscription_events` stores `(event_id, type, stripe_subscription_id)` and handlers skip re-delivery.

## Data Model

- Tables: `overage_items`, `overage_purchases`, `overage_credits`, `user_subscriptions`, `subscription_plans`, `subscription_plan_prices`, `subscription_usage`, `entitlement_consumptions`, `stripe_subscription_events`, `stripe_customers`.
- FK: `entitlement_consumptions.overage_purchase_id` (provenance of overage-linked consumptions).
- Sources: `entitlement_consumptions.source ∈ {'subscription','credit','overage'}`.
- Functions: `fn_reserve_chat|video`, `fn_commit_consumption`, `fn_release_consumption`, `fn_current_usage`.
- Unique Indexes:
  - Single consumption per `overage_purchase_id` (enforced by `uniq_consumptions_overage_purchase`).
  - Pending guard for one `(session_id, consumption_type, source)` non-finalized record.

## Current Status — Verified

- Overage credits auto-draw in `sessions/start` (chat): decrements credits and avoids overage prompt.
- Session end flow: commits when `consumptionId` provided; returns `ended: true`.
- Overage checkout → payment → session-bound auto-consume or credit fallback.
- Idempotency: webhook re-delivery is ignored via `stripe_subscription_events`.

## Missing / To Validate

- Failure/refund paths: exercise with Stripe CLI and confirm transitions and credit reversals/compensation.
- Idempotent re-delivery: resend identical events and confirm no double consume/credit.
- Recurring membership smoke: end-to-end plan checkout → webhook → `user_subscriptions` upsert consistency.
- Admin/Ops UI: items CRUD (enable/disable), lists for purchases/consumptions/credits, bind overage to current session.
- Reporting: lightweight usage/overage summaries and exports.
- Concurrency tests: simultaneous `sessions/start` requests consuming credits.
- Runbooks: manual consume workflow, refund expectations, credit adjustment policies, Stripe event mapping.

## What To Test Next
- Admin guard: call admin endpoints with and without `x-admin-secret`; expect `admin_forbidden` when missing/mismatch. Set `ADMIN_PRICING_SYNC_SECRET` (or `ADMIN_SECRET`).
- Session overage: start session without entitlements/credits; verify response includes `payment.url` and a `checkout_created` purchase bound to `original_session_id`.
- Unique index: attempt double consume linking the same `overage_purchase_id`; expect DB error or endpoint `reason` indicating duplicate prevented.
- Webhook idempotency: resend `checkout.session.completed` for same `session_id`; expect handler to skip.

## Work Plan — One by One
- Replace stub `POST /subscriptions/checkout` with real Stripe path or deprecate; standardize on `stripe/checkout`.
- Sessions overage: implement one-off checkout creation + return URL when `pending_payment` would occur.
- Guard admin endpoints: move `mark-paid`, `mark-refunded`, `adjust-credits` under `admin/overage/*` with secret/role.
- Item CRUD: `POST /admin/overage/items` (create/update/deactivate), plus list endpoints.
- Add unique index: prevent double consume on same `overage_purchase_id`.
- Add user invoices/billing history endpoint.
- OpenAPI: reflect all current/added endpoints with clear status and error enums.
- Observability: health endpoints for search/AI/queue; rate limits on hot paths.

## OpenAPI Spec Updates — Proposed

- Add `sessions` endpoints and payloads:
  - `POST /sessions/start` request/response including `credit` block and `overage` stub structure.
  - `POST /sessions/end` request accepts `sessionId` and optional `consumptionId`.
  - `GET /sessions`, `GET /sessions/{sessionId}`, `PATCH /sessions/{sessionId}`.
- Subscriptions lifecycle:
  - `POST /subscriptions/stripe/checkout` with `plan_code`, `success_url`, `cancel_url`.
  - `POST /subscriptions/cancel|resume|change-plan` with clear schemas and error reasons.
  - `GET /subscriptions/usage`, `GET /subscriptions/usage/current`, `GET /subscriptions/my`.
- Overage flows:
  - `POST /subscriptions/overage/checkout` with `code`, `quantity`, optional `original_session_id`.
  - `POST /subscriptions/overage/consume` request/response with `mode='purchase'|'credit'`.
  - `GET /subscriptions/overage/items`, `GET /subscriptions/overage/credits`.
- Admin pricing:
  - `POST /admin/pricing/sync` guarded by `x-admin-secret`.
- Internal Stripe:
  - `POST /internal/stripe/event` secret-guarded; minimal envelope `{id,type,data}`.
- Common error reasons & enums:
  - Standardize `reason` strings (e.g., `no_active_subscription`, `plan_not_found`, `no_purchase_or_credit_available`, `already_has_active_subscription`).

## Try It — Quick Curl

```sh
# Plans
curl -sS "$SERVER_URL/plans" | jq

# Start chat session with auto-credit draw
curl -sS -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  "$SERVER_URL/sessions/start" -d '{"type":"chat"}' | jq

# Overage checkout for chat unit (bind to session)
curl -sS -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  "$SERVER_URL/subscriptions/overage/checkout" -d '{"code":"chat_unit","original_session_id":"<SESSION_ID>"}' | jq

# Webhooks (internal)
curl -sS -X POST -H "x-internal-secret:$INTERNAL_STRIPE_EVENT_SECRET" -H 'Content-Type: application/json' \
  "$SERVER_URL/internal/stripe/event" -d '{"id":"evt_...","type":"checkout.session.completed","data":{...}}' | jq
```

---

If you want, I can now update the OpenAPI files under `docs/openapi/` to reflect these endpoints and payloads, starting with `openapi.yaml` and adding `sessions` + `subscriptions/overage` contracts.