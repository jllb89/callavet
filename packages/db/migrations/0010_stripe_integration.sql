-- 0010_stripe_integration.sql
-- Add Stripe subscription/customer ids and event idempotency table

ALTER TABLE user_subscriptions
  ADD COLUMN IF NOT EXISTS stripe_subscription_id text,
  ADD COLUMN IF NOT EXISTS stripe_customer_id text;

CREATE TABLE IF NOT EXISTS stripe_subscription_events (
  event_id text PRIMARY KEY,
  created_at timestamptz DEFAULT now(),
  type text,
  stripe_subscription_id text
);

-- Index for quick lookup by stripe_subscription_id
CREATE INDEX IF NOT EXISTS idx_stripe_subscription_events_subscription
  ON stripe_subscription_events (stripe_subscription_id);
