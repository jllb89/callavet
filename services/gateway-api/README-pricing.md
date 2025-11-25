# Pricing & Stripe Mapping

## Overview
We store Stripe price/product references alongside internal subscription plans.

### Schema Additions
- `subscription_plans`: columns `stripe_product_id`, `stripe_price_id` (single primary price).
- `subscription_plan_prices`: flexible table for multiple prices (monthly/yearly, currencies, regions). Unique active per (plan, billing_period, currency).

### Lookup Flow
`PriceService.getActivePrice(planCode, billingPeriod, currency)`:
1. Query `subscription_plan_prices` for active row.
2. Fallback to `subscription_plans.stripe_price_id`.
3. Cache entries for 60s TTL.
4. Legacy fallback to `STRIPE_PRICE_<CODE>` env var until migration populated.

### Stripe Sync
`StripeSyncService.sync()` pulls Stripe products & prices, matches by `plan_code` metadata, and upserts into `subscription_plan_prices`.

Add `plan_code=<internal_code>` metadata to Stripe Product or Price so reconciliation works.

### Migration Steps
1. Apply migration `0013_plan_prices.sql` to staging/prod.
2. Populate `subscription_plans.stripe_price_id` for each active plan (temporary).
3. (Optional) Run sync job to backfill `subscription_plan_prices`.
4. Remove env var fallback after verification.

### Manual Backfill Example
```sql
update subscription_plans set stripe_product_id='prod_ABC', stripe_price_id='price_ABC' where lower(code)='starter';
update subscription_plans set stripe_product_id='prod_DEF', stripe_price_id='price_DEF' where lower(code)='plus';
```

### Future Enhancements
- Add admin UI for pricing updates (create new Stripe Price, deactivate old row).
- Add background cron: periodic sync + stale cache purge.
- Support trial days: store `trial_days` in flexible table; pass to Stripe subscription_data.
- Multi-currency: insert one row per currency; adjust checkout currency parameter.

### Operational Playbook
- New price: Create Product/Price in Stripe (or just Price if Product unchanged) with metadata `plan_code`.
- Run sync service or admin action to ingest.
- Update features/quota in `subscription_plans` if needed.
- Monitor logs: `Stripe sync complete: inserted=.. updated=.. skipped=..`.

### Removing Legacy Fallback
After all plans have DB-based `stripe_price_id` and `subscription_plan_prices` rows:
1. Delete the fallback environment variables.
2. Remove fallback code in `stripeCheckout`.
3. Reduce TTL or implement fine-grained invalidation on price changes.

### Safety Checks
- Ensure Stripe secret is set before sync; otherwise no writes.
- Validate price id pattern `^price_` and product id pattern `^prod_` before persisting.
- Consider soft-deactivating prices instead of hard deletes so historical references remain stable.

### Monitoring
Add counters:
- `pricing_cache_hits`, `pricing_cache_misses`.
- `stripe_sync_inserted`, `stripe_sync_updated`, `stripe_sync_skipped`.
Expose via metrics endpoint later.

---
This doc summarizes current pricing architecture transition from env vars to DB-driven mapping.
