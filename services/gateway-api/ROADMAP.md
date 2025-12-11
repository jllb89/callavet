# Gateway API Roadmap — Group-by-Group Delivery Plan

This is the implementation roadmap derived from `services/gateway-api/README.md`. We will proceed group by group, implementing missing controllers/endpoints and adding a smoke test script per group. Order and dependencies are chosen to minimize context switching and ensure each group can be validated end-to-end before moving on.

Status tags
- verified: already implemented + validated
- implement: needs controller/endpoint implementation
- align: minor spec/runtime alignment or validation remaining
- script: write/run a smoke script to validate the group

## Execution Order (High-Level)
1) System + Docs + Internal Billing
2) Auth & Profile (`me/*`)
3) Plans & Subscriptions (user + admin overages)
4) Sessions (start/end + patch/list/detail)
5) Messages (non-session scoped)
6) KB, Vector & Search
7) Pets (complete CRUD + pet files)
8) Centers
9) Payments & Invoices (read-only per spec)
10) Notifications
11) Files (generic)
12) Admin Ops (users, subscriptions, credits, refunds, plans, coupons, analytics)
13) Webhooks (raw signed)
14) Video
15) Notes & Care Plans
16) Image Cases
17) Appointments
18) AI (internal)

Rationale: Start with core runtime already present (1–6) to lock in foundations and data flows. Then expand entities (7–8), billing artifacts (9), platform features (10–11), administrative operations (12), and external integrations (13–18).

---

## 1) System + Docs + Internal Billing
- Controllers: `health.controller.ts` (verified), `meta.controller.ts` (verified), `docs.controller.ts` (verified), `db.controller.ts` (verified), `internal-billing-health.controller.ts` (verified)
- Endpoints: `GET /health`, `GET /version`, `GET /time`, `GET /openapi.yaml`, `GET /docs`, `GET /openapi-chat-ws.yaml`, `GET /openapi-webhooks.yaml`, `GET /docs/chat`, `GET /docs/webhooks`, `GET /_db/status`, `GET /internal/billing/health` — verified
- Test script: align
  - Script: `env/scripts/smoke-system-docs.sh` — script
  - Validations: 200 responses, basic content keys

## 2) Auth & Profile (`me/*`)
- Controllers: `me.controller.ts` — verified
- Endpoints: `GET /me`, `PATCH /me`, `GET /me/security/sessions`, `POST /me/security/logout-all`, `POST /me/security/logout-all-supabase`, `GET /me/billing-profile`, `PUT /me/billing-profile`, `POST /me/billing/payment-method/attach`, `DELETE /me/billing/payment-method/:pmId` — verified
- Test script
  - Script: `env/scripts/smoke-me.sh` — script
  - Validations: JWT required, profile update round-trip, billing profile upsert, attach/detach PM (stub/real depending env)

## 3) Plans & Subscriptions (User + Admin Overages)
- Controllers: `subscriptions.controller.ts`, `admin-pricing.controller.ts` — mostly verified
- User Endpoints
  - Verified: debug/auth/db-status/active; `GET /subscriptions/overage/items`, `GET /subscriptions/overage/credits`
  - Implement/align: `POST /subscriptions/stripe/checkout`, `POST /subscriptions/checkout` (alias/decision), `POST /subscriptions/portal`, `POST /subscriptions/overage/checkout`, `POST /subscriptions/overage/consume`, `POST /subscriptions/cancel`, `POST /subscriptions/resume`, `POST /subscriptions/change-plan`, `POST /subscriptions/reserve-chat`, `POST /subscriptions/reserve-video`, `POST /subscriptions/commit`, `POST /subscriptions/release`, `GET /subscriptions/usage`, `GET /subscriptions/my`, `GET /subscriptions/usage/current` — align
- Admin Overages Endpoints
  - Verified: list items, upsert items, purchases, consumptions, adjust-credits
  - Implement/align: `POST /subscriptions/admin/overage/mark-paid`, `POST /subscriptions/admin/overage/mark-refunded` — align
- Plans Endpoints
  - `GET /plans`, `GET /plans/:code` — align
- Test scripts
  - `env/scripts/smoke-openapi-admin-overage.sh` — verified baseline
  - `env/scripts/smoke-subscriptions.sh` — script
    - Validations: plan checkout payload, portal placeholder, overage checkout/consume, usage snapshots, cancel/resume/change-plan flows
  - Spec alignment notes
    - Prefer `POST /subscriptions/overage/checkout` for one-off overage; do not duplicate under `/payments/one-off/checkout`
    - Confirm alias `POST /subscriptions/checkout` necessity; otherwise consolidate under `POST /subscriptions/stripe/checkout`

## 4) Sessions
- Controllers: `sessions.controller.ts` — verified core
- Endpoints: `GET /sessions`, `GET /sessions/:sessionId`, `PATCH /sessions/:sessionId`, `POST /sessions/start`, `POST /sessions/end` — verified/align
- Test script
  - `env/scripts/smoke-sessions.sh` — script
  - Validations: start credit draw vs overage path (payment fields), concurrency behavior, end commit with `consumptionId`

## 5) Messages
- Controllers: `messages.controller.ts` — verified non-session scoped
- Endpoints: `GET /messages`, `GET /messages/transcripts`, `GET /messages/:id` — align
 - Spec alignment: session-scoped paths (`/sessions/{sessionId}/messages`, `/sessions/{sessionId}/transcript`) are not implemented; either add later or update spec to reflect current non-session-scoped design
- Test script
  - `env/scripts/smoke-messages.sh` — script
  - Validations: list/transcripts/detail fetch, paging baseline

## 6) KB, Vector & Search
- Controllers: `kb.controller.ts`, `vector.controller.ts`, `search.controller.ts` — verified
- Endpoints: `GET /kb`, `GET /kb/:id`, `POST /kb`, `PATCH /kb/:id/publish`, `POST/GET /vector/search`, `POST /vector/upsert`, `GET /vector/debug`, `GET /vector/pets`, `GET /search` — align
- Test script
  - `env/scripts/smoke-kb-vector-search.sh` — script
  - Validations: publish lifecycle, ANN search (POST/GET), upsert vector, pets embedding flags, lexical search

## 7) Pets (complete CRUD + pet files)
- Controllers: `pets.controller.ts` — currently list/detail only
- Endpoints
  - Verified: `GET /pets`, `GET /pets/:petId`
  - Implement: `POST /pets`, `PATCH /pets/:petId`, `DELETE /pets/:petId`, `POST /pets/:petId/files/signed-url` — implement
- Test script
  - `env/scripts/smoke-pets.sh` — script
  - Validations: create→get→patch→delete lifecycle; signed-url

## 8) Centers
- Controllers: `centers.controller.ts` — verified `near`
- Endpoints
  - Verified: `GET /centers/near`
  - Implement (spec-only): detail/admin CRUD + vet-center assign/unassign — implement
 - Spec alignment: confirm which admin center operations are truly needed; add only those with UI consumers to avoid dead surfaces
- Test script
  - `env/scripts/smoke-centers.sh` — script
  - Validations: nearby query, admin create/update/detail, vet-center assignment

## 9) Payments & Invoices (read-only per spec)
- Controllers: payments, invoices — implement (read-only)
- Endpoints:
  - Implement: `GET /payments`, `GET /payments/:paymentId`, `GET /invoices`, `GET /invoices/:invoiceId`
  - Defer: `POST /payments/one-off/checkout` — prefer `POST /subscriptions/overage/checkout` to avoid duplication
- Data source: reuse normalized Stripe data from `POST /internal/stripe/event` ingestion
- Test script
  - `env/scripts/smoke-payments-invoices.sh` — script
  - Validations: list/detail responses match OpenAPI shapes; no new Stripe flows

## 10) Notifications
- Controllers: none — implement
- Endpoints: `POST /notifications/test` — implement; `POST /notifications/receipt` (if kept) — implement
- Test script
  - `env/scripts/smoke-notifications.sh` — script
  - Validations: send test across channels; receipt persistence

## 11) Files (generic)
- Controllers: none — implement
- Endpoints: `POST /files/signed-url`, `GET /files/download-url` — implement
- Test script
  - `env/scripts/smoke-files.sh` — script
  - Validations: signed upload→download URL

## 12) Admin Ops
- Controllers: none — implement
- Endpoints: `GET /admin/users`, `GET /admin/users/:userId`, `GET /admin/subscriptions`, `POST /admin/credits/grant`, `POST /admin/refunds`, `POST /admin/vets/:vetId/approve`, `POST /admin/plans`, `POST /admin/coupons`, `GET /admin/analytics/usage` — implement
 - Spec alignment: guard all with `x-admin-secret`; ensure response shapes match OpenAPI examples minimally
- Test script
  - `env/scripts/smoke-admin-ops.sh` — script
  - Validations: each admin operation guarded and functional

## 13) Webhooks (raw signed)
- Controllers: none — implement
- Endpoints: `POST /webhooks/stripe` — implement
- Coordination: forward raw Stripe webhook → internal handler (`POST /internal/stripe/event`)
 - Spec alignment: keep `POST /internal/stripe/ingest` internal-only; primary external is raw signed webhook
- Test script
  - `env/scripts/smoke-webhooks-raw.sh` — script
  - Validations: signature verify (stub in dev), pass-through to internal event, idempotent replay behavior

## 14) Video
- Controllers: none — implement
- Endpoints: `POST /video/rooms`, `POST /video/rooms/:roomId/end` — implement
- Test script
  - `env/scripts/smoke-video.sh` — script
  - Validations: room create returns token; end locks room

## 15) Notes & Care Plans (verified)
- Controllers: `SessionNotesController` (sessions), `NotesController` (care plans/items) — verified
- Endpoints: `GET /sessions/:sessionId/notes` (ListNotes), `POST /sessions/:sessionId/notes` (Notes), `GET/POST /pets/:petId/care-plans`, `GET/POST /care-plans/:planId/items`, `PATCH /care-plans/items/:itemId` — verified
- Access rules:
  - Owners: only notes/care plans for their pets
  - Vets: notes they authored and all notes for sessions where they are the assigned vet
  - Admins: full access
- Read-paths: bind user id via decoded claims (`sub`) to avoid environment `auth.uid()` drift
- Test scripts
  - `env/scripts/smoke-session-notes.sh` — POST + GET
  - `env/scripts/smoke-session-notes-vet.sh` — vet visibility check
  - `env/scripts/smoke-care-plan-items.sh` — create/list/fulfill
  - Validations: owner and vet-session flows return non-empty lists when `PET_ID` belongs to bearer and session is attached

## 16) Image Cases
- Controllers: none — implement
- Endpoints: `GET/POST /pets/:petId/image-cases`, `GET /image-cases/:id` — implement
- Test script
  - `env/scripts/smoke-image-cases.sh` — script
  - Validations: create/list/detail

## 17) Appointments
- Controllers: none — implement
- Endpoints: `GET/POST /appointments`, `PATCH /appointments/:id`, `GET /vets/:vetId/availability/slots` — implement
- Test script
  - `env/scripts/smoke-appointments.sh` — script
  - Validations: booking, status updates, slots listing

## 18) AI (internal)
- Controllers: none — implement
- Endpoints: `POST /internal/embeddings/backfill`, `POST /internal/summaries/generate` — implement
- Test script
  - `env/scripts/smoke-ai-internal.sh` — script
  - Validations: backfill limited run; summaries generation stubs

---

## Cross-Cutting Tasks & Dependencies
- Stripe webhook idempotency reason: add distinct `reason:"ignored_duplicate"` (Internal Stripe event) — implement early in Group 3/13
- Auth: ensure `SB_ACCESS_TOKEN` is available to all smoke scripts (we’ll reuse the staging env pattern)
- Admin guarding: use `x-admin-secret` consistently; for new admin controllers, centralize guard logic
- Observability: add route tags/logs incrementally per group
- Error reasons: align with `ErrorReason` enum in OpenAPI when implementing new endpoints
 - Spec checks: before starting each group, re-read `docs/openapi/openapi.yaml` for that tag and list exact paths + response schemas to avoid divergence

## Smoke Script Conventions
- All scripts live under `env/scripts/`
- Each script:
  - Sources `./.env.staging` (`set -a && source ... && set +a`)
  - Uses `Authorization: Bearer $SB_ACCESS_TOKEN` when needed
  - Prints compact PASS/FAIL per endpoint

## Suggested Weekly Cadence
- Week 1: Finalize Group 3 (Subscriptions) + Group 4 (Sessions) scripts; fix webhook replay reason
- Week 2: Group 5–6 (Messages, KB/Vector/Search)
- Week 3: Group 7–9 (Pets CRUD + Centers + Payments)
- Week 4: Group 10–12 (Notifications, Files, Admin Ops)
- Week 5: Group 13–18 (Webhooks raw, Video, Notes/Care Plans, Image Cases, Appointments, AI)
