-- 0012_unique_stripe_subscription.sql
-- Enforce uniqueness of stripe_subscription_id when present.

CREATE UNIQUE INDEX IF NOT EXISTS user_subscriptions_stripe_subscription_uidx
  ON user_subscriptions (stripe_subscription_id)
  WHERE stripe_subscription_id IS NOT NULL;
