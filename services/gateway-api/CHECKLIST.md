# OpenAPI Pre-Implementation Checklists (Per Group)

Use this as a template before coding each group. For every path: verify runtime controller presence, auth/guards, and response schema alignment. Tick boxes as you validate.

Legend
- [ ] pending
- [x] verified

## System
- [x] GET /health → responses: Ok
- [x] GET /version → responses: Ok
- [x] GET /time → responses: inline object { now }
- [x] GET /openapi.yaml → responses: spec file
- [x] GET /docs → responses: static
- [x] GET /openapi-chat-ws.yaml → responses: spec file
- [x] GET /openapi-webhooks.yaml → responses: spec file
- [x] GET /docs/chat → responses: static
- [x] GET /docs/webhooks → responses: static
- [x] GET /_db/status → responses: inline object (snapshot)

## Auth & Profile (me)
- [x] GET /me → responses: Me
- [x] PATCH /me → responses: Me
- [x] GET /me/security/sessions → responses: List
- [x] POST /me/security/logout-all → responses: inline object { userId, revoked, stub }
- [x] POST /me/security/logout-all-supabase → responses: inline object { ok, mode, reason, error, hint }
- [x] GET /me/billing-profile → responses: BillingProfile
- [x] PUT /me/billing-profile → responses: BillingProfile
- [x] POST /me/billing/payment-method/attach → responses: StripeSetup
- [ ] DELETE /me/billing/payment-method/{pmId} → responses: 204 No Content

Routing Notes (Frontend)
- Base URL: use `GATEWAY_BASE` (fallback `SERVER_URL`) from env.
- Auth: send `Authorization: Bearer ${SB_ACCESS_TOKEN}` on all `me/*` routes.
- Content-Type: `application/json` for `PATCH /me` and `PUT /me/billing-profile`.
- Patch schema: body must match `#/components/requestBodies/MePatch`.
- Billing profile upsert: body must match `#/components/requestBodies/BillingProfile`.
- Payment method detach: path param `pmId` is required; expect `204` with empty body.
- Sessions list: plain list per `#/components/responses/List`; do not paginate yet.
- Logout-all: returns `{ userId, revoked, stub }`; show success with `revoked > 0`.
- Logout-all-supabase: returns `{ ok, mode, reason, error, hint }`; handle non-`ok` without retry.
- Error handling: on `401` redirect to login; on `400` surface `reason` string when present.

## Plans & Subscriptions
- [x] GET /plans → responses: ListPlans
- [x] GET /plans/{code} → responses: Plan
- [x] GET /subscriptions/my → responses: ListSubscriptions
- [x] GET /subscriptions/usage/current → responses: Usage | ApiError
- [x] POST /subscriptions/checkout → responses: StripeCheckout | ApiError
- [x] POST /subscriptions/portal → responses: StripePortal | ApiError
- [x] POST /subscriptions/cancel → responses: Subscription | ApiError
- [x] POST /subscriptions/resume → responses: Subscription | ApiError
- [x] POST /subscriptions/change-plan → responses: Subscription | ApiError
- [x] POST /subscriptions/stripe/checkout → responses: inline { ok }
- [x] GET /subscriptions/usage → responses: inline { ok, msg, usage }
- [x] POST /subscriptions/reserve-chat → responses: inline (additionalProperties)
- [ ] POST /subscriptions/reserve-video → responses: inline (additionalProperties)
- [x] POST /subscriptions/commit → responses: inline { ok }
- [x] POST /subscriptions/release → responses: inline { ok }

Routing Notes (Frontend)
- Base URL: use `GATEWAY_BASE` (fallback `SERVER_URL`).
- Public endpoints: `GET /plans`, `GET /plans/{code}` can be unauthenticated.
- Auth required: all `/subscriptions/*` and `/subscriptions/usage*` need bearer.
- Headers: `Authorization: Bearer ${SB_ACCESS_TOKEN}`; JSON bodies for POST.
- Checkout flow: `POST /subscriptions/checkout` returns `{ url, session_id }`; redirect to `url`.
- Portal: `POST /subscriptions/portal` returns `{ url }` to customer portal.
- Usage: prefer `GET /subscriptions/usage/current` for current snapshot; legacy `GET /subscriptions/usage` returns `{ ok, msg, usage }`.
- Reserve/commit/release: transactional inline responses; handle `ok: false` `reason` strings.
- Change/cancel/resume: update subscription object; surface `ApiError.reason` on failure.
- Overage checkout: use `/subscriptions/overage/checkout` for one-off units; do not implement `/payments/one-off/checkout`.
	- Verified: `/subscriptions/overage/items`, `/subscriptions/overage/credits`, `/subscriptions/overage/checkout`.

### Admin Overage (verified)
- [x] GET /subscriptions/admin/overage/purchases → responses: examples (purchases[]) | ApiError
- [x] GET /subscriptions/admin/overage/consumptions → responses: examples (consumptions[]) | ApiError
- [x] POST /subscriptions/admin/overage/mark-paid → responses: examples { ok, previous_status, new_status, consumed } | ApiError
- [x] POST /subscriptions/admin/overage/mark-refunded → responses: examples { ok, previous_status, new_status, credits_reversed } | ApiError
- [x] POST /subscriptions/admin/overage/adjust-credits → responses: examples { ok, code, delta, remaining } | ApiError
- [x] GET/POST /subscriptions/admin/overage/items → responses: examples { ok, items | ok, item } | ApiError

## Sessions
- [x] GET /sessions → responses: ListSessions | inline list
- [x] GET /sessions/{sessionId} → responses: Session
- [x] PATCH /sessions/{sessionId} → responses: Session
- [x] POST /sessions/start → responses: SessionStartResponse | SessionStart
- [x] POST /sessions/end → responses: SessionEndResponse | Session

Routing Notes (Frontend)
- Base URL: `GATEWAY_BASE` (fallback `SERVER_URL`).
- Auth: Bearer required for all `/sessions/*` endpoints.
- List: `GET /sessions?limit=20&offset=0` returns `{ data: [...] }`; defaults `limit=20`, `offset=0`, max `limit=100`.
- Detail: `GET /sessions/{id}` returns session row; `404` if not owned.
- Patch: `PATCH /sessions/{id}` body `{ status: 'active|completed|canceled' }`; sets `ended_at` when completed/canceled.
- Start: `POST /sessions/start` accepts `{ kind|mode|type: 'chat'|'video' }` and returns either credit-backed or overage payment object.
- End: `POST /sessions/end` body `{ sessionId, consumptionId? }`; commits consumption when provided.
- Errors: `400` with reason strings like `list_failed`, `detail_failed`, `patch_failed`, `start_failed`, `end_failed`; `404` when not found.

## Messages
- [x] GET /sessions/{sessionId}/messages → responses: ListMessages
- [x] POST /sessions/{sessionId}/messages → responses: Message
- [x] GET /sessions/{sessionId}/transcript → responses: Transcript
- [ ] GET /messages → responses: inline list (runtime)
- [ ] GET /messages/transcripts → responses: inline list (runtime)
- [x] GET /messages/{id} → responses: Message (runtime)

Routing Notes (Frontend)
- Session-scoped: prefer `GET/POST /sessions/{sessionId}/messages` and `GET /sessions/{sessionId}/transcript` per spec.
- Global endpoints exist: `GET /messages`, `GET /messages/transcripts`, `GET /messages/{id}`; detail is live; list/transcripts pending.
- Auth: Bearer required for all messages endpoints.
- Create body: `{ role: 'user'|'vet'|'ai', content: string }`.
- Response shapes: list returns `{ ok, sessionId, items[] }`; create returns `{ ok, sessionId, message{...} }`; transcript returns `{ ok, sessionId, transcript[] }`.

## KB & Search
- [ ] GET /kb → responses: ListKB
- [ ] POST /kb → responses: KBItem
- [ ] GET /kb/{id} → responses: KBItem
- [ ] POST /vector/search → responses: inline { results[] }
- [ ] GET /vector/search → responses: inline { results[] }
- [ ] GET /vector/debug → responses: inline { pets, pets_with_emb, sample[] }
- [ ] GET /vector/pets → responses: inline { items[] }
- [ ] GET /search → responses: inline { items[], took_ms, lexical }

## Pets
- [ ] GET /pets → responses: ListPets
- [ ] POST /pets → responses: 201 Pet
- [ ] GET /pets/{petId} → responses: Pet
- [ ] PATCH /pets/{petId} → responses: Pet
- [ ] DELETE /pets/{petId} → responses: 204 No Content
- [ ] POST /pets/{petId}/files/signed-url → responses: SignedUrl

## Centers
- [ ] GET /centers/near → responses: ListCenters
- [ ] (spec-only) Implement detail/admin CRUD + vet-center assign/unassign if needed

## Payments & Invoices (read-only)
- [ ] GET /payments → responses: ListPayments
- [ ] GET /payments/{paymentId} → responses: Payment
- [ ] GET /invoices → responses: ListInvoices
- [ ] GET /invoices/{invoiceId} → responses: Invoice
- [ ] Defer: POST /payments/one-off/checkout (use subscriptions overage checkout)

## Notifications
- [ ] POST /notifications/test → responses: Ok
- [ ] (optional) POST /notifications/receipt → responses: Ok

## Files (generic)
- [ ] POST /files/signed-url → responses: SignedUrl
- [ ] GET /files/download-url → responses: SignedUrl

## Admin Ops
- [ ] GET /admin/users → responses: ListUsers
- [ ] GET /admin/users/{userId} → responses: User
- [ ] GET /admin/subscriptions → responses: ListSubscriptions
- [ ] POST /admin/credits/grant → responses: Ok
- [ ] POST /admin/refunds → responses: Payment
- [ ] POST /admin/vets/{vetId}/approve → responses: Vet
- [ ] POST /admin/plans → responses: Plan
- [ ] POST /admin/coupons → responses: Ok (201)
- [ ] GET /admin/analytics/usage → responses: Ok

## Webhooks
- [ ] POST /webhooks/stripe → responses: Ok
- [ ] Internal: POST /internal/stripe/event → responses: Ok (ensure reason: ignored_duplicate on replay)
- [ ] Internal: POST /internal/stripe/ingest → responses: Ok

## Video
- [ ] POST /video/rooms → responses: VideoRoom
- [ ] POST /video/rooms/{roomId}/end → responses: Ok

## Notes & Care Plans
- [ ] GET /sessions/{sessionId}/notes → responses: Notes
- [ ] POST /sessions/{sessionId}/notes → responses: Notes
- [ ] GET /pets/{petId}/care-plans → responses: ListCarePlans
- [ ] POST /pets/{petId}/care-plans → responses: CarePlan (201)
- [ ] GET /care-plans/{planId}/items → responses: ListCarePlanItems
- [ ] POST /care-plans/{planId}/items → responses: CarePlanItem (201)
- [ ] PATCH /care-plans/items/{itemId} → responses: CarePlanItem

## Image Cases
- [ ] GET /pets/{petId}/image-cases → responses: ListImageCases
- [ ] POST /pets/{petId}/image-cases → responses: ImageCase (201)
- [ ] GET /image-cases/{id} → responses: ImageCase

## Appointments
- [ ] GET /appointments → responses: ListAppointments
- [ ] POST /appointments → responses: Appointment (201)
- [ ] PATCH /appointments/{id} → responses: Appointment
- [ ] GET /vets/{vetId}/availability/slots → responses: ListSlots

## AI (internal)
- [ ] POST /internal/embeddings/backfill → responses: Ok (202)
- [ ] POST /internal/summaries/generate → responses: Ok (202)

---

How to use
- Before coding a group: tick through each path, confirm controllers and guards, and copy response shapes from OpenAPI to tests.
- After coding: run the group smoke script, then mark items [x] when responses match.
