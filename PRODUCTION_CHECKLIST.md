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
- Rollout: Staging smoke tests; cutover plan; feature flags if needed.
