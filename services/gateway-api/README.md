# Gateway API — Subscriptions, Sessions, Overage, Stripe

This document inventories all implemented endpoints, internal flows, data models, Stripe webhook handling, and idempotency. It also lists missing items and proposed spec updates to keep contracts aligned.

## API Groups

- `subscriptions`: plans, lifecycle, overage, usage, entitlements
- `sessions`: chat/video session lifecycle, entitlement consumption
- `admin/pricing`: Stripe products/prices reconciliation
- `internal/stripe`: webhook ingestion (secret-guarded)

## Subscriptions

- `POST /subscriptions/checkout`
  - DB-only checkout stub that creates a local active subscription and usage row.
  - Returns subscription + plan attributes.
- `POST /subscriptions/stripe/checkout`
  - Creates Stripe Checkout Session for recurring plans.
  - Attaches `metadata.user_id` to session and subscription.
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
- `POST /subscriptions/overage/checkout`
  - Creates one-off Stripe Checkout Session for overage items (chat/video units).
  - Persists `overage_purchases` with `status='checkout_created'` and optional `original_session_id`.
- `POST /subscriptions/overage/consume`
  - Manual consume: links paid purchase to a session consumption (`overage_purchase_id`) or decrements credits if no session binding.
- `GET /subscriptions/overage/items`
  - Lists active overage catalog items.
- `GET /subscriptions/overage/credits`
  - Lists remaining credit units per item for the current user.
- `POST /subscriptions/cancel`
  - Cancels active subscription: immediate or at period end.
- `POST /subscriptions/resume`
  - Resumes a scheduled cancellation.
- `POST /subscriptions/change-plan`
  - Changes plan code and updates included usage counts.
- `POST /subscriptions/reserve-chat`
  - Calls `fn_reserve_chat(sessionId)` to reserve a chat entitlement.
- `POST /subscriptions/reserve-video`
  - Calls `fn_reserve_video(sessionId)` to reserve a video entitlement.
- `POST /subscriptions/commit`
  - Finalizes a pending consumption (`fn_commit_consumption`).
- `POST /subscriptions/release`
  - Releases a pending consumption (`fn_release_consumption`).
- `GET /subscriptions/usage`
  - Returns full usage from `fn_current_usage` for the active subscription.
- `GET /subscriptions/my`
  - Lists user subscriptions with embedded plan details.
- `GET /subscriptions/usage/current`
  - Minimal snapshot of current period usage.

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
- `POST /sessions/start`
  - Creates a session, reserves entitlement via `fn_reserve_*`.
  - Auto-credit draw when subscription entitlement exhausted: decrement `overage_credits` and insert `entitlement_consumptions` with `source='credit'`.
  - If still exhausted, marks session `pending_payment` and returns `overage: true` with payment stub.
- `POST /sessions/end`
  - Marks session ended; commits `consumptionId` if provided.

## Admin Pricing

- `POST /admin/pricing/sync`
  - Admin-only endpoint (guarded by `x-admin-secret`) to reconcile Stripe Products/Prices into `subscription_plan_prices`.

## Internal Stripe Webhooks

- `POST /internal/stripe/event`
  - Secret-guarded ingestion. Records idempotency in `stripe_subscription_events` and dispatches handlers.

### Handled Events

- `customer.subscription.created|updated|deleted`
  - Upserts `user_subscriptions` with status mapping, period start/end, cancel flags.
  - Resolves plan via `subscription_plan_prices` (fallback legacy columns).
- `invoice.payment_succeeded|invoice.payment_failed`
  - Updates `user_subscriptions.status` to `active|past_due`.
- `checkout.session.completed`
  - Marks `overage_purchases` `paid`.
  - If `original_session_id` exists and user has active subscription, inserts `entitlement_consumptions` with `source='overage'` and sets `consumed`.
  - Otherwise, credits units (`overage_credits`) and sets `credited`.
- `payment_intent.succeeded`
  - Same side-effects as `checkout.session.completed` for purchases keyed by `stripe_payment_intent_id`.
- `payment_intent.payment_failed`
  - Marks `overage_purchases` `failed`.
- `charge.refunded|charge.refund.updated`
  - Marks `overage_purchases` `refunded`.
  - Reverses credits if previously `credited`.
  - Optional compensating credit for `consumed` when `OVERAGE_REFUND_GRANT_CREDIT=1`.

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
  - Single consumption per `overage_purchase_id`.
  - Pending guard for one `(session_id, consumption_type, source)` non-finalized record.

## Current Status — Verified

- Overage credits auto-draw in `sessions/start` (chat): decrements credits and avoids overage prompt.
- Session end flow: commits when `consumptionId` provided; returns `ended: true`.
- Overage checkout → payment → session-bound auto-consume or credit fallback.
- Idempotency: webhook re-delivery is ignored via `stripe_subscription_events`.

## Missing / To Validate

- Video parity: verify auto-credit draw and overage prompt for `type='video'`.
- Failure/refund paths: exercise with Stripe CLI and confirm status transitions and credit reversals/compensation.
- Idempotent re-delivery: resend identical events and confirm no double consume/credit.
- Recurring membership smoke: end-to-end plan checkout → webhook → `user_subscriptions` upsert consistency.
- Admin/Ops UI: items CRUD (enable/disable), lists for purchases/consumptions/credits, bind overage to current session.
- Reporting: lightweight usage/overage summaries and exports.
- Concurrency tests: simultaneous `sessions/start` requests consuming credits.
- Runbooks: manual consume workflow, refund expectations, credit adjustment policies, Stripe event mapping.

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