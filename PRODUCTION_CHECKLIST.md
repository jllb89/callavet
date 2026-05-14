# Production Checklist

- Webhooks: Confirm production Stripe webhook pointing to `https://cav-webhooks-staging-ugvx.onrender.com/stripe/webhook` (or prod URL). Set `STRIPE_WEBHOOK_SECRET` from Dashboard. Keep `stripe listen` only for local.
- Billing: Verify `cancel_at_period_end` propagation both directions; test immediate cancel + resume flows.
- Entitlements: Ensure `fn_reserve_chat/video` SECURITY DEFINER functions are applied; remove any controller fallbacks (done).
- Overage: End-to-end flow for one-off purchases (checkout session, webhook, consumption record). Verify "overage" source in `entitlement_consumptions`.
- Pricing: Run admin sync (`POST /admin/pricing/sync`) and confirm `subscription_plan_prices` align with Stripe products/prices.
- Auth: Validate JWT handling across routes; confirm `auth.uid()` matches `claims.sub` in transactions.
- DB: RLS policies audited; verify views vs underlying tables for active subscription visibility.
- Infra: Configure environment variables (Stripe keys/secrets, Supabase URL/anon/service keys). Set `DATABASE_URL` with `sslmode=require`.
- Observability: Add request IDs and context tags for subscriptions/sessions; basic metrics for cache hits/misses.
- Backups: Enable scheduled backups or point-in-time recovery for Postgres.
- Security: Rate limits for key endpoints; validate input across subscription/session routes.
- Support: Admin tools for refunds/credits, logout-all, pricing controls; logging for billing events.
- Performance: Verify pgvector index settings and analyze after embeddings backfill.
- AI: Apply migration `0051`; set `AI_PROVIDER`, `AI_PROVIDER_BASE_URL`, `AI_API_MODE`, `AI_PROVIDER_API_KEY` or `OPENAI_API_KEY`, `AI_MODEL`, `AI_EMBEDDING_MODEL`, `AI_REASONING_EFFORT`, and `AI_REQUEST_TIMEOUT_MS`; verify feature flags in `ai_feature_flags`; run dry-run and real-provider AI smokes before launch.
- Rollout: Staging smoke tests; cutover plan; feature flags if needed.

## Phase 5 AI Launch Gates

1. Apply `0051_phase5_ai_triage_referral_drafting.sql` to staging and production.
2. Set provider config in gateway environment:
	- `AI_PROVIDER=openai` or the OpenAI-compatible provider name.
	- `AI_PROVIDER_BASE_URL=https://api.openai.com/v1` unless using another compatible endpoint.
	- `AI_API_MODE=responses` for OpenAI's current Responses API.
	- `AI_PROVIDER_API_KEY` or `OPENAI_API_KEY`.
	- `AI_MODEL`, for example `gpt-5.5`; use `gpt-5.4-mini` if latency/cost is the tighter constraint.
	- `AI_EMBEDDING_MODEL`, for example `text-embedding-3-small`.
	- `AI_REASONING_EFFORT`, for example `low` for staging smoke and routine draft generation.
	- `AI_REQUEST_TIMEOUT_MS`, default-safe value `30000`.
3. Confirm DB feature flags that should launch are enabled:
	- `ai.triage`
	- `ai.referral`
	- `ai.note_draft`
	- `ai.care_plan_draft`
	- `ai.embeddings_generation`
4. Run validation gates after redeploy:
	- `bash env/scripts/smoke-phase5-ai.sh` for dry-run persistence, reviewable draft/event coverage, and embedding generation coverage.
	- A real-provider triage or note-draft request with `dryRun=false` using staging-safe case data.
	- `bash env/scripts/smoke-backend-core.sh`
	- `zsh env/scripts/smoke-admin-ops.sh`
	- `bash env/scripts/smoke-phase4-clinical-record.sh`
5. Keep AI output review-only. Do not auto-create referrals, notes, or care plans from AI drafts until a clinician workflow explicitly accepts them.

## Phase 6 Runbooks

### 1) Backups and Restore Verification

Goal: prove we can restore service data without production DB console access.

Steps:
1. Confirm automated backups / PITR are enabled in Supabase project settings.
2. Record current backup policy: cadence, retention, restore target (staging project).
3. Run a restore drill into staging from a recent snapshot.
4. Validate restored data integrity via deployment gates:
	- `zsh env/scripts/smoke-backend-core.sh`
	- `zsh env/scripts/smoke-admin-ops.sh`
5. Capture restore metadata: backup timestamp, restore duration, smoke outcome.

Operational guardrails:
- Never run restore drills directly into prod.
- Keep restore drill evidence in release notes for each production cut.

### 2) Webhook Replay (Stripe and LiveKit)

Goal: safely replay missed/delayed events and verify idempotency.

Steps:
1. Identify incident window and affected event IDs.
2. Replay Stripe events through internal ingest route with internal secret:
	- `POST /internal/stripe/event`
3. Replay LiveKit signed webhooks against webhooks service endpoint:
	- `POST /livekit/webhook`
4. Verify no duplicate side effects:
	- `stripe_subscription_events` idempotency behavior
	- `livekit_video_events` + `video_session_lifecycle` state consistency
5. Run focused post-replay checks:
	- `GET /admin/notifications/events`
	- `GET /admin/video/sessions`

Operational guardrails:
- Replay in chronological order where possible.
- Use narrow windows to avoid replay storms.

### 3) Refund Side Effects

Goal: ensure refunds keep credits/entitlements/subscriptions consistent.

Steps:
1. Create refund from admin endpoint:
	- `POST /admin/refunds`
2. Validate Stripe/webhook side effects:
	- `charge.refunded` and related update handlers applied once.
3. Validate domain state:
	- overage purchase status transitions
	- overage credit decrement/reversal behavior
	- entitlement consumption consistency for session-linked usage
4. Verify support visibility:
	- `GET /admin/audit/logs`
	- `GET /admin/export/sessions`

Operational guardrails:
- Always include `requestId` for idempotent refund operations.
- Never issue duplicate manual refunds for same payment intent.

### 4) Incident Handling (P1/P2)

Goal: rapid triage and containment for chat/video/notifications failures.

Severity model:
- P1: user-facing outage (gateway unavailable, mass room issuance failures, auth collapse).
- P2: degraded function (notification provider failures, elevated ws auth failures, partial endpoint errors).

Playbook:
1. Detect and classify from `GET /admin/ops/dashboard` alerts.
2. Contain:
	- freeze risky rollouts,
	- disable non-critical toggles/paths,
	- preserve idempotency and data safety.
3. Diagnose via exports and admin logs:
	- `GET /admin/audit/logs`
	- `GET /admin/notifications/events`
	- `GET /admin/video/sessions`
4. Recover with the smallest safe change (config fix, rollback, replay, or targeted patch).
5. Verify recovery gates:
	- `zsh env/scripts/smoke-backend-core.sh`
	- `zsh env/scripts/smoke-admin-ops.sh`
6. Publish incident summary with timeline, root cause, and prevention tasks.

Escalation triggers:
- Any `critical` alert in ops dashboard.
- Notification failure spikes and queue growth that do not stabilize within one observation window.
- Repeated forced-ended / timed-out video sessions above baseline.
