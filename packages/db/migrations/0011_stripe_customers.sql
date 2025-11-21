-- 0011_stripe_customers.sql
-- Map Stripe customer IDs to internal user IDs for fallback inserts

CREATE TABLE IF NOT EXISTS stripe_customers (
  user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  stripe_customer_id text UNIQUE NOT NULL,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_stripe_customers_stripe_customer_id ON stripe_customers (stripe_customer_id);
