# iOS Apple Account Gaps and Roadmap

_Last updated: 2026-03-11_

## Purpose
This document captures what is still missing (and why) while the Apple Developer Business account is pending, plus the current implementation status across subscriptions, auth hardening, and iOS-specific features like Dynamic Island and Live Activities.

## Current Implementation Status (Done)

### Auth + KYC hardening completed
- OTP flow is now tested with `BYPASS_OTP=false` and user data saves to the correct row.
- Dev startup session reset was added to avoid stale-session cross-user updates.
- BYPASS mode now requires a valid active session match to prevent patching a different user.
- `customer_type` is required in DB and included in KYC persistence + login completeness checks.

### Subscription platform groundwork completed
- DB migration applied for Apple scaffolding:
  - `subscription_plan_provider_products`
  - `apple_subscription_events`
- New gateway endpoints added:
  - `POST /subscriptions/apple/verify`
  - `POST /internal/apple/event`
- OpenAPI updated with Apple verify/ingest request bodies and endpoint contracts.
- Env placeholders added:
  - `INTERNAL_APPLE_EVENT_SECRET` in staging/prod env files.

### Twilio testing relief completed
- Test destination was added to Twilio Global Safe List and verified via API (`POST` + `GET`).

---

## What is Blocked by Missing Apple Business Account

## 1) App Store Connect subscription products
Blocked tasks:
- Create app record and configure paid apps agreements.
- Configure subscriptions and product IDs (monthly/annual per plan strategy).
- Define subscription groups, pricing tiers, localized metadata, and review assets.

Impact:
- Cannot map real Apple product IDs into `subscription_plan_provider_products`.
- Cannot run true end-to-end Apple purchase/renewal/cancel flows.

## 2) Apple server-side validation readiness
Blocked tasks:
- Configure App Store Server API credentials and environment setup.
- Configure App Store Server Notifications v2 destination and signing verification workflow.

Impact:
- Current `POST /subscriptions/apple/verify` is scaffold-level and marked pending for full Apple server validation.

## 3) TestFlight / Sandbox purchase validation at scale
Blocked tasks:
- Full purchase QA with real Apple subscription objects across intro offers, renewals, cancellation, grace/billing retry.

Impact:
- Apple billing behavior cannot be certified for production readiness yet.

## 4) Push entitlements and iOS account-level capabilities
Blocked/partially blocked tasks:
- Final APNs production credentials and account-level setup.
- Production signing/capability rollout for features dependent on Apple account configuration.

Impact:
- Limits production-grade testing for notification and activity update reliability.

---

## Dynamic Island + Live Activities (Requested Scope)

## What is likely missing today
- No confirmed production rollout of ActivityKit-based Live Activities with backend push updates.
- No confirmed App Store/Apple account-level completion for production live activity push pipeline.

## Required for full implementation
1. iOS app side
- ActivityKit integration for target use cases (session status, vet ETA, countdowns, etc.).
- Dynamic Island compact/expanded/minimal UI states.
- Local + remote update handling and expiry behavior.

2. Backend side
- Event model for activity lifecycle (`start`, `update`, `end`).
- APNs push type `liveactivity` support and token management.
- Retry/idempotency + observability for update delivery.

3. Apple account/capabilities
- Push Notifications capability enabled and correctly provisioned for all environments.
- Live Activities entitlement and signing/capability validation across profiles.

## Recommendation while account is pending
- Keep Live Activities behind a feature flag and implement UI/data contracts now.
- Defer production push wiring until Apple account/certs are fully available.

---

## What We Can Keep Building Now (No Apple account required)

1. Provider-agnostic subscription UX
- Keep plan catalog and entitlement logic provider-neutral.
- Add provider-aware labels in app (`Stripe`, `Apple`) where helpful.

2. Product mapping prep
- Draft SQL templates to map Apple product IDs once available.
- Define 1:1 mapping policy between business plans and Apple SKUs.

3. Feature flag strategy
- Keep `APPLE_IAP_ENABLED=false` by default.
- Expose non-blocking fallback messaging on iOS until products are active.

4. Verification hardening
- Add stricter validation/error schemas for Apple verify payloads.
- Add tests for duplicate event handling and idempotent upserts.

---

## Suggested Go-Live Exit Criteria (Apple)
- Apple product IDs configured and mapped for all intended plans.
- Successful end-to-end purchase + renewal + cancellation in sandbox/TestFlight.
- Server notification ingestion verified with signature checks and replay safety.
- Subscription state reflected correctly in `user_subscriptions` with `provider='apple'`.
- Entitlements unaffected by provider differences.
- iOS paywall compliant with Apple IAP policy.
- Live Activities (if included in scope) pass reliability checks for start/update/end lifecycle.

---

## Related Files (Current Work)
- `packages/db/migrations/0039_subscription_provider_apple_scaffold.sql`
- `services/gateway-api/src/modules/subscriptions/subscriptions.controller.ts`
- `services/gateway-api/src/modules/billing/internal-apple.controller.ts`
- `services/gateway-api/src/modules/billing/internal-apple.service.ts`
- `services/gateway-api/src/modules/billing/billing.module.ts`
- `docs/openapi/openapi.yaml`
- `.env.staging`
- `.env.prod`
