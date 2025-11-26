-- 0018_cleanup_legacy_rows.sql
-- Clean legacy test subscription rows that have no Stripe linkage and are canceled.
-- Safe: only removes rows with status='canceled' AND stripe_subscription_id IS NULL.

SET search_path = public;

-- First delete entitlement_consumptions linked to legacy canceled subs
DELETE FROM entitlement_consumptions ec
 WHERE EXISTS (
   SELECT 1 FROM user_subscriptions s
    WHERE s.id = ec.subscription_id
      AND s.stripe_subscription_id IS NULL
      AND s.status = 'canceled'
 );

-- First delete usage rows belonging to legacy canceled subscriptions (no stripe id)
DELETE FROM subscription_usage su
 WHERE EXISTS (
   SELECT 1 FROM user_subscriptions s
    WHERE s.id = su.subscription_id
      AND s.stripe_subscription_id IS NULL
      AND s.status = 'canceled'
 );

-- Then delete those legacy canceled subscriptions
DELETE FROM user_subscriptions
 WHERE stripe_subscription_id IS NULL
   AND status = 'canceled';

-- Finally, prune any orphaned usage rows (defensive)
DELETE FROM subscription_usage su
 WHERE NOT EXISTS (
   SELECT 1 FROM user_subscriptions s WHERE s.id = su.subscription_id
 );
