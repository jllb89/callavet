-- 0013_plan_prices.sql
-- Introduce Stripe product/price mapping into subscription_plans and flexible plan pricing table.
-- This migration is additive and non-breaking; existing code can fall back until refactor completed.

-- Add columns to subscription_plans (if table exists) for direct mapping.
-- If your actual table name differs (e.g. plans vs subscription_plans), adjust accordingly.
ALTER TABLE subscription_plans
  ADD COLUMN IF NOT EXISTS stripe_product_id text,
  ADD COLUMN IF NOT EXISTS stripe_price_id text;

-- Ensure we can reference multiple prices (e.g. monthly/yearly, currencies, regions)
CREATE TABLE IF NOT EXISTS subscription_plan_prices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id uuid REFERENCES subscription_plans(id) ON DELETE CASCADE,
  stripe_product_id text NOT NULL,
  stripe_price_id text NOT NULL,
  billing_period text NOT NULL CHECK (billing_period IN ('month','year')),
  currency text NOT NULL DEFAULT 'usd',
  region text, -- optional for future geo pricing
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_subscription_plan_prices_plan ON subscription_plan_prices(plan_id);
CREATE UNIQUE INDEX IF NOT EXISTS u_subscription_plan_prices_unique_active ON subscription_plan_prices(plan_id, billing_period, currency)
  WHERE is_active;

-- Trigger to keep updated_at fresh
CREATE OR REPLACE FUNCTION trg_subscription_plan_prices_touch()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;$$ LANGUAGE plpgsql;

CREATE TRIGGER subscription_plan_prices_touch
  BEFORE UPDATE ON subscription_plan_prices
  FOR EACH ROW EXECUTE FUNCTION trg_subscription_plan_prices_touch();
