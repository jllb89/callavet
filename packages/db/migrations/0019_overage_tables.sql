-- 0019_overage_tables.sql
SET search_path = public;

CREATE TABLE IF NOT EXISTS overage_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text UNIQUE NOT NULL,
  name text NOT NULL,
  description text,
  currency text NOT NULL,
  amount_cents integer NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  metadata jsonb DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS overage_purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  overage_item_id uuid NOT NULL REFERENCES overage_items(id) ON DELETE RESTRICT,
  status text NOT NULL,
  stripe_checkout_session_id text UNIQUE,
  stripe_payment_intent_id text UNIQUE,
  quantity integer NOT NULL DEFAULT 1,
  amount_cents_total integer NOT NULL,
  currency text NOT NULL,
  original_session_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS overage_credits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  overage_item_id uuid NOT NULL REFERENCES overage_items(id) ON DELETE RESTRICT,
  remaining_units integer NOT NULL DEFAULT 0,
  expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, overage_item_id)
);

-- Link consumptions to purchases
ALTER TABLE entitlement_consumptions
  ADD COLUMN IF NOT EXISTS overage_purchase_id uuid REFERENCES overage_purchases(id) ON DELETE SET NULL;
