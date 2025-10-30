-- ============================================================
-- Call a Vet (MX-first) — Full Schema + Upgrades + Helpers
-- ============================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS pgcrypto; -- for gen_random_uuid()

-- ------------------------------------------------------------
-- Bilingual tsvector helper (Spanish + English)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION es_en_tsv(input text)
RETURNS tsvector
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
  SELECT
    to_tsvector('spanish', unaccent(coalesce($1,''))) ||
    to_tsvector('english', unaccent(coalesce($1,'')));
$$;

-- ============================================================
-- USERS
-- ============================================================
CREATE TABLE IF NOT EXISTS users (
  id uuid PRIMARY KEY,
  email text UNIQUE NOT NULL,
  full_name text,
  phone text,
  role text CHECK (role IN ('user', 'vet', 'admin')) DEFAULT 'user',
  is_verified boolean DEFAULT false,
  created_at timestamp DEFAULT now(),
  updated_at timestamp DEFAULT now(),
  deleted_at timestamp,
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS users_tsv_gin ON users USING GIN (search_tsv);

-- ============================================================
-- PETS (patients)
-- ============================================================
CREATE TABLE IF NOT EXISTS pets (
  id uuid PRIMARY KEY,
  user_id uuid REFERENCES users(id),
  name text NOT NULL,
  species text NOT NULL,
  breed text,
  birthdate date,
  sex text,
  weight_kg float,
  medical_notes text,
  embedding vector(1536),
  created_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS pets_tsv_gin ON pets USING GIN (search_tsv);
CREATE INDEX IF NOT EXISTS pets_emb_ivfflat ON pets USING ivfflat (embedding vector_cosine_ops) WITH (lists=100);
CREATE INDEX IF NOT EXISTS pets_user_idx ON pets (user_id);

-- ============================================================
-- VET SPECIALTIES
-- ============================================================
CREATE TABLE IF NOT EXISTS vet_specialties (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  description text,
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS vet_specialties_tsv_gin ON vet_specialties USING GIN (search_tsv);

-- ============================================================
-- VETS
-- ============================================================
CREATE TABLE IF NOT EXISTS vets (
  id uuid PRIMARY KEY REFERENCES users(id),
  license_number text,
  country text,
  bio text,
  years_experience int,
  is_approved boolean DEFAULT false,
  specialties uuid[],
  languages text[] DEFAULT '{}',
  embedding vector(1536),
  created_at timestamp DEFAULT now(),
  updated_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS vets_tsv_gin ON vets USING GIN (search_tsv);
CREATE INDEX IF NOT EXISTS vets_emb_ivfflat ON vets USING ivfflat (embedding vector_cosine_ops) WITH (lists=100);

-- ============================================================
-- PRODUCTS
-- ============================================================
CREATE TABLE IF NOT EXISTS products (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  description text,
  meta_words text[],
  tags text[] DEFAULT '{}',
  embedding vector(1536),
  price_cents integer,
  is_active boolean DEFAULT true,
  created_at timestamp DEFAULT now(),
  updated_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS products_tsv_gin ON products USING GIN (search_tsv);
CREATE INDEX IF NOT EXISTS products_emb_ivfflat ON products USING ivfflat (embedding vector_cosine_ops) WITH (lists=100);
CREATE INDEX IF NOT EXISTS products_active_idx ON products (is_active);

-- ============================================================
-- SERVICE PROVIDERS
-- ============================================================
CREATE TABLE IF NOT EXISTS service_providers (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  description text,
  type text CHECK (type IN ('clinic', 'pharmacy', 'grooming', 'transport', 'retail')) NOT NULL,
  contact_email text,
  phone text,
  website text,
  location text,
  is_verified boolean DEFAULT false,
  created_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS service_providers_tsv_gin ON service_providers USING GIN (search_tsv);

-- ============================================================
-- SERVICES
-- ============================================================
CREATE TABLE IF NOT EXISTS services (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  description text,
  price_cents integer,
  provider_id uuid REFERENCES service_providers(id),
  is_active boolean DEFAULT true,
  tags text[] DEFAULT '{}',
  embedding vector(1536),
  created_at timestamp DEFAULT now(),
  updated_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS services_tsv_gin ON services USING GIN (search_tsv);
CREATE INDEX IF NOT EXISTS services_emb_ivfflat ON services USING ivfflat (embedding vector_cosine_ops) WITH (lists=100);
CREATE INDEX IF NOT EXISTS services_provider_idx ON services (provider_id);

-- ============================================================
-- VET CARE CENTERS / CLINICS
-- ============================================================
CREATE TABLE IF NOT EXISTS vet_care_centers (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  description text,
  address text,
  phone text,
  email text,
  website text,
  geo_location text,
  is_partner boolean DEFAULT false,
  created_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS vet_care_centers_tsv_gin ON vet_care_centers USING GIN (search_tsv);

-- ============================================================
-- VET ↔ CLINIC AFFILIATIONS
-- ============================================================
CREATE TABLE IF NOT EXISTS vet_clinic_affiliations (
  id uuid PRIMARY KEY,
  vet_id uuid REFERENCES vets(id),
  clinic_id uuid REFERENCES vet_care_centers(id),
  role text,
  created_at timestamp DEFAULT now()
);
CREATE INDEX IF NOT EXISTS vca_vet_idx ON vet_clinic_affiliations (vet_id);
CREATE INDEX IF NOT EXISTS vca_clinic_idx ON vet_clinic_affiliations (clinic_id);

-- ============================================================
-- CHAT SESSIONS
-- ============================================================
CREATE TABLE IF NOT EXISTS chat_sessions (
  id uuid PRIMARY KEY,
  user_id uuid REFERENCES users(id),
  vet_id uuid REFERENCES vets(id),
  pet_id uuid REFERENCES pets(id),
  product_id uuid REFERENCES products(id),
  status text,
  started_at timestamp,
  ended_at timestamp,
  created_at timestamp DEFAULT now(),
  updated_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS chat_sessions_user_idx ON chat_sessions (user_id);
CREATE INDEX IF NOT EXISTS chat_sessions_vet_idx ON chat_sessions (vet_id);
CREATE INDEX IF NOT EXISTS chat_sessions_pet_idx ON chat_sessions (pet_id);
CREATE INDEX IF NOT EXISTS chat_sessions_tsv_gin ON chat_sessions USING GIN (search_tsv);

-- ============================================================
-- MESSAGES
-- ============================================================
CREATE TABLE IF NOT EXISTS messages (
  id uuid PRIMARY KEY,
  session_id uuid REFERENCES chat_sessions(id),
  sender_id uuid REFERENCES users(id),
  role text CHECK (role IN ('user', 'vet', 'ai')),
  content text NOT NULL,
  embedding vector(1536),
  created_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS messages_session_idx ON messages (session_id);
CREATE INDEX IF NOT EXISTS messages_sender_idx ON messages (sender_id);
CREATE INDEX IF NOT EXISTS messages_tsv_gin ON messages USING GIN (search_tsv);
CREATE INDEX IF NOT EXISTS messages_emb_ivfflat ON messages USING ivfflat (embedding vector_cosine_ops) WITH (lists=100);

-- ============================================================
-- CONSULTATION NOTES
-- ============================================================
CREATE TABLE IF NOT EXISTS consultation_notes (
  id uuid PRIMARY KEY,
  session_id uuid REFERENCES chat_sessions(id),
  vet_id uuid REFERENCES vets(id),
  pet_id uuid REFERENCES pets(id),
  summary_text text,
  plan_summary text,
  embedding vector(1536),
  created_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS consultation_notes_session_idx ON consultation_notes (session_id);
CREATE INDEX IF NOT EXISTS consultation_notes_pet_idx ON consultation_notes (pet_id);
CREATE INDEX IF NOT EXISTS consultation_notes_tsv_gin ON consultation_notes USING GIN (search_tsv);
CREATE INDEX IF NOT EXISTS consultation_notes_emb_ivfflat ON consultation_notes USING ivfflat (embedding vector_cosine_ops) WITH (lists=100);

-- ============================================================
-- CARE PLANS
-- ============================================================
CREATE TABLE IF NOT EXISTS care_plans (
  id uuid PRIMARY KEY,
  pet_id uuid REFERENCES pets(id),
  created_by_ai boolean DEFAULT true,
  short_term text,
  mid_term text,
  long_term text,
  embedding vector(1536),
  created_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS care_plans_pet_idx ON care_plans (pet_id);
CREATE INDEX IF NOT EXISTS care_plans_tsv_gin ON care_plans USING GIN (search_tsv);
CREATE INDEX IF NOT EXISTS care_plans_emb_ivfflat ON care_plans USING ivfflat (embedding vector_cosine_ops) WITH (lists=100);

-- ============================================================
-- PLAN SUBSCRIPTIONS (legacy care plan sales)
-- ============================================================
CREATE TABLE IF NOT EXISTS plans_subscriptions (
  id uuid PRIMARY KEY,
  pet_id uuid REFERENCES pets(id),
  care_plan_id uuid REFERENCES care_plans(id),
  user_id uuid REFERENCES users(id),
  price_cents integer,
  discount_pct integer,
  is_active boolean DEFAULT true,
  expires_at timestamp,
  created_at timestamp DEFAULT now()
);
CREATE INDEX IF NOT EXISTS plans_subscriptions_pet_idx ON plans_subscriptions (pet_id);
CREATE INDEX IF NOT EXISTS plans_subscriptions_user_idx ON plans_subscriptions (user_id);
CREATE INDEX IF NOT EXISTS plans_subscriptions_active_idx ON plans_subscriptions (is_active);

-- ============================================================
-- CARE PLAN ITEMS
-- ============================================================
CREATE TABLE IF NOT EXISTS care_plan_items (
  id uuid PRIMARY KEY,
  care_plan_id uuid REFERENCES care_plans(id),
  type text CHECK (type IN ('consult', 'vaccine', 'product')),
  description text,
  price_cents integer,
  fulfilled boolean DEFAULT false,
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS care_plan_items_plan_idx ON care_plan_items (care_plan_id);
CREATE INDEX IF NOT EXISTS care_plan_items_fulfilled_idx ON care_plan_items (fulfilled);
CREATE INDEX IF NOT EXISTS care_plan_items_tsv_gin ON care_plan_items USING GIN (search_tsv);

-- ============================================================
-- GLOBAL PET HEALTH DATA
-- ============================================================
CREATE TABLE IF NOT EXISTS global_pet_health_data (
  id uuid PRIMARY KEY,
  species text,
  breed text,
  sex text,
  age_years float,
  weight_kg float,
  geo_region text,
  symptoms text[],
  diagnosis_label text,
  consult_date date,
  notes text,
  embedding vector(1536),
  source_type text CHECK (source_type IN ('ai_generated', 'vet_written', 'user_reported')),
  consultation_id uuid REFERENCES chat_sessions(id),
  created_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS global_pet_health_data_tsv_gin ON global_pet_health_data USING GIN (search_tsv);
CREATE INDEX IF NOT EXISTS global_pet_health_data_emb_ivfflat ON global_pet_health_data USING ivfflat (embedding vector_cosine_ops) WITH (lists=100);
CREATE INDEX IF NOT EXISTS global_pet_health_data_consult_date_idx ON global_pet_health_data (consult_date);

-- ============================================================
-- KNOWLEDGE BASE
-- ============================================================
CREATE TABLE IF NOT EXISTS kb_items (
  id uuid PRIMARY KEY,
  title text NOT NULL,
  body text NOT NULL,
  species text[],
  tags text[],
  embedding vector(1536),
  version int DEFAULT 1,
  created_by uuid REFERENCES users(id),
  created_at timestamp DEFAULT now(),
  updated_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS kb_items_tsv_gin ON kb_items USING GIN (search_tsv);
CREATE INDEX IF NOT EXISTS kb_items_emb_ivfflat ON kb_items USING ivfflat (embedding vector_cosine_ops) WITH (lists=100);

-- ============================================================
-- Vet Availability & Appointments
-- ============================================================
CREATE TABLE IF NOT EXISTS vet_availability (
  id uuid PRIMARY KEY,
  vet_id uuid REFERENCES vets(id),
  weekday int CHECK (weekday BETWEEN 0 AND 6),
  start_time time,
  end_time time,
  timezone text
);
CREATE INDEX IF NOT EXISTS vet_availability_vet_idx ON vet_availability (vet_id);

CREATE TABLE IF NOT EXISTS appointments (
  id uuid PRIMARY KEY,
  session_id uuid REFERENCES chat_sessions(id),
  vet_id uuid REFERENCES vets(id),
  user_id uuid REFERENCES users(id),
  starts_at timestamptz,
  ends_at timestamptz,
  status text CHECK (status IN ('scheduled','active','completed','no_show','canceled')),
  created_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS appointments_vet_idx ON appointments (vet_id, starts_at);
CREATE INDEX IF NOT EXISTS appointments_user_idx ON appointments (user_id, starts_at);
CREATE INDEX IF NOT EXISTS appointments_status_idx ON appointments (status);
CREATE INDEX IF NOT EXISTS appointments_tsv_gin ON appointments USING GIN (search_tsv);

-- ============================================================
-- Subscriptions (Stripe-first; video by COUNT; pets seats)
-- ============================================================

-- Billing profile (Stripe customer, prefs)
CREATE TABLE IF NOT EXISTS billing_profiles (
  user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  stripe_customer_id text UNIQUE,
  default_payment_method text,
  billing_address jsonb,
  tax_id text,
  preferred_language text CHECK (preferred_language IN ('es','en')) DEFAULT 'es',
  timezone text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- Plan catalog
CREATE TABLE IF NOT EXISTS subscription_plans (
  id uuid PRIMARY KEY,
  code text UNIQUE NOT NULL,
  name text NOT NULL,
  description text,
  price_cents int NOT NULL,
  currency text DEFAULT 'MXN',
  billing_period text CHECK (billing_period IN ('month','year')) DEFAULT 'month',
  included_chats int DEFAULT 0,
  included_videos int DEFAULT 0,          -- COUNT of videos
  pets_included_default int DEFAULT 1,    -- seats for pets/patients
  tax_rate numeric DEFAULT 0.16,
  stripe_product_id text,
  stripe_price_id text,
  is_active boolean DEFAULT true,
  created_at timestamp DEFAULT now(),
  updated_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS subscription_plans_active_idx ON subscription_plans (is_active);
CREATE INDEX IF NOT EXISTS subscription_plans_tsv_gin ON subscription_plans USING GIN (search_tsv);

-- User subscriptions
CREATE TABLE IF NOT EXISTS user_subscriptions (
  id uuid PRIMARY KEY,
  user_id uuid REFERENCES users(id) NOT NULL,
  plan_id uuid REFERENCES subscription_plans(id) NOT NULL,
  status text CHECK (status IN ('trialing','active','past_due','canceled','expired')) NOT NULL DEFAULT 'active',
  started_at timestamptz DEFAULT now(),
  current_period_start timestamptz NOT NULL,
  current_period_end timestamptz NOT NULL,
  cancel_at_period_end boolean DEFAULT false,
  canceled_at timestamptz,
  trial_end timestamptz,
  override_price_cents int,
  tax_rate numeric DEFAULT 0.16,
  auto_renew boolean DEFAULT true,
  provider text DEFAULT 'stripe',
  provider_subscription_id text,
  provider_customer_id text,
  pets_included int,                      -- override seats; NULL → use plan default
  created_at timestamp DEFAULT now(),
  updated_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS user_subscriptions_user_idx ON user_subscriptions (user_id);
CREATE INDEX IF NOT EXISTS user_subscriptions_status_idx ON user_subscriptions (status);
CREATE INDEX IF NOT EXISTS user_subscriptions_period_idx ON user_subscriptions (current_period_start, current_period_end);
CREATE INDEX IF NOT EXISTS user_subscriptions_tsv_gin ON user_subscriptions USING GIN (search_tsv);

-- Period usage snapshot (entitlements)
CREATE TABLE IF NOT EXISTS subscription_usage (
  id uuid PRIMARY KEY,
  subscription_id uuid REFERENCES user_subscriptions(id) NOT NULL,
  period_start timestamptz NOT NULL,
  period_end timestamptz NOT NULL,
  included_chats int DEFAULT 0,
  included_videos int DEFAULT 0,
  consumed_chats int DEFAULT 0,
  consumed_videos int DEFAULT 0,
  overage_chats int DEFAULT 0,
  overage_videos int DEFAULT 0,
  updated_at timestamp DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS subscription_usage_unique_period
  ON subscription_usage (subscription_id, period_start, period_end);

-- Consumption audit
CREATE TABLE IF NOT EXISTS entitlement_consumptions (
  id uuid PRIMARY KEY,
  subscription_id uuid REFERENCES user_subscriptions(id) NOT NULL,
  session_id uuid REFERENCES chat_sessions(id),
  consumption_type text CHECK (consumption_type IN ('chat','video')) NOT NULL,
  amount int NOT NULL,                         -- chats count or video count (1)
  source text,                                 -- 'system','admin','adjustment'
  finalized boolean DEFAULT false,
  canceled_at timestamptz,
  created_at timestamp DEFAULT now()
);
CREATE INDEX IF NOT EXISTS entitlement_consumptions_sub_idx ON entitlement_consumptions (subscription_id, created_at);
CREATE INDEX IF NOT EXISTS entitlement_consumptions_session_idx ON entitlement_consumptions (session_id);

-- Convenience view: active subs now
CREATE OR REPLACE VIEW v_active_user_subscriptions AS
SELECT s.*
FROM user_subscriptions s
WHERE s.status IN ('trialing','active')
  AND now() >= s.current_period_start
  AND now() <  s.current_period_end
  AND (s.cancel_at_period_end IS FALSE OR s.cancel_at_period_end IS NULL);

-- ============================================================
-- Payments (sessions & subscriptions; Stripe)
-- ============================================================
CREATE TABLE IF NOT EXISTS payments (
  id uuid PRIMARY KEY,
  user_id uuid REFERENCES users(id),
  session_id uuid REFERENCES chat_sessions(id),       -- nullable (one-off consult)
  subscription_id uuid REFERENCES user_subscriptions(id), -- nullable (invoices)
  amount_cents int,
  currency text DEFAULT 'MXN',
  provider text DEFAULT 'stripe',
  provider_payment_id text,
  status text CHECK (status IN ('requires_payment','paid','refunded','failed')),
  tax_rate numeric,
  created_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS payments_user_idx ON payments (user_id, created_at);
CREATE INDEX IF NOT EXISTS payments_session_idx ON payments (session_id);
CREATE INDEX IF NOT EXISTS payments_status_idx ON payments (status);
CREATE UNIQUE INDEX IF NOT EXISTS payments_provider_pid_uniq ON payments (provider, provider_payment_id);
CREATE INDEX IF NOT EXISTS payments_tsv_gin ON payments USING GIN (search_tsv);

-- Optional invoices (CFDI metadata)
CREATE TABLE IF NOT EXISTS invoices (
  id uuid PRIMARY KEY,
  user_id uuid REFERENCES users(id),
  subscription_id uuid REFERENCES user_subscriptions(id),
  provider text DEFAULT 'stripe',
  provider_invoice_id text,
  amount_cents int,
  currency text DEFAULT 'MXN',
  tax_rate numeric DEFAULT 0.16,
  status text CHECK (status IN ('open','paid','void','uncollectible','refunded')),
  issued_at timestamptz DEFAULT now(),
  cfdi_uuid text,
  fiscal_meta jsonb,
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS invoices_user_idx ON invoices (user_id, issued_at);
CREATE INDEX IF NOT EXISTS invoices_sub_idx ON invoices (subscription_id, issued_at);
CREATE UNIQUE INDEX IF NOT EXISTS invoices_provider_id_uniq ON invoices (provider, provider_invoice_id);
CREATE INDEX IF NOT EXISTS invoices_tsv_gin ON invoices USING GIN (search_tsv);

-- ============================================================
-- Ratings
-- ============================================================
CREATE TABLE IF NOT EXISTS ratings (
  id uuid PRIMARY KEY,
  session_id uuid REFERENCES chat_sessions(id),
  vet_id uuid REFERENCES vets(id),
  user_id uuid REFERENCES users(id),
  score int CHECK (score BETWEEN 1 AND 5),
  comment text,
  created_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS ratings_vet_idx ON ratings (vet_id);
CREATE INDEX IF NOT EXISTS ratings_session_idx ON ratings (session_id);
CREATE INDEX IF NOT EXISTS ratings_tsv_gin ON ratings USING GIN (search_tsv);

-- ============================================================
-- Phase 2: Image Cases
-- ============================================================
CREATE TABLE IF NOT EXISTS image_cases (
  id uuid PRIMARY KEY,
  pet_id uuid REFERENCES pets(id),
  session_id uuid REFERENCES chat_sessions(id),
  image_url text,
  labels text[],
  findings text,
  diagnosis_label text,
  image_embedding vector(1536),
  created_at timestamp DEFAULT now(),
  search_tsv tsvector
);
CREATE INDEX IF NOT EXISTS image_cases_tsv_gin ON image_cases USING GIN (search_tsv);
CREATE INDEX IF NOT EXISTS image_cases_emb_ivfflat ON image_cases USING ivfflat (image_embedding vector_cosine_ops) WITH (lists=100);
CREATE INDEX IF NOT EXISTS image_cases_pet_idx ON image_cases (pet_id);

-- ============================================================
-- Atomic Entitlement Helpers (counts)
-- ============================================================

-- Ensure/return current period usage row
CREATE OR REPLACE FUNCTION fn_current_usage(p_subscription_id uuid)
RETURNS subscription_usage
LANGUAGE plpgsql
AS $$
DECLARE
  s user_subscriptions;
  u subscription_usage;
  p subscription_plans;
BEGIN
  SELECT * INTO s FROM user_subscriptions WHERE id = p_subscription_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'subscription % not found', p_subscription_id;
  END IF;

  SELECT * INTO p FROM subscription_plans WHERE id = s.plan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'plan % not found for subscription %', s.plan_id, p_subscription_id;
  END IF;

  SELECT * INTO u
  FROM subscription_usage
  WHERE subscription_id = s.id
    AND period_start = s.current_period_start
    AND period_end   = s.current_period_end
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO subscription_usage (
      id, subscription_id, period_start, period_end,
      included_chats, included_videos,
      consumed_chats, consumed_videos
    ) VALUES (
      gen_random_uuid(), s.id, s.current_period_start, s.current_period_end,
      p.included_chats, p.included_videos,
      0, 0
    )
    RETURNING * INTO u;
  END IF;

  RETURN u;
END;
$$;

-- Reserve one CHAT
CREATE OR REPLACE FUNCTION fn_reserve_chat(p_user_id uuid, p_session_id uuid)
RETURNS TABLE(ok boolean, subscription_id uuid, consumption_id uuid, msg text)
LANGUAGE plpgsql
AS $$
DECLARE
  s user_subscriptions;
  u subscription_usage;
  c_id uuid;
BEGIN
  SELECT *
    INTO s
  FROM v_active_user_subscriptions
  WHERE user_id = p_user_id
  ORDER BY current_period_end DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, 'no_active_subscription';
    RETURN;
  END IF;

  u := fn_current_usage(s.id);

  UPDATE subscription_usage
     SET consumed_chats = consumed_chats + 1,
         updated_at = now()
   WHERE id = u.id
     AND consumed_chats < included_chats
  RETURNING * INTO u;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, s.id, NULL::uuid, 'no_chat_entitlement_left';
    RETURN;
  END IF;

  INSERT INTO entitlement_consumptions (
    id, subscription_id, session_id, consumption_type, amount, source, created_at
  ) VALUES (
    gen_random_uuid(), s.id, p_session_id, 'chat', 1, 'system', now()
  ) RETURNING id INTO c_id;

  RETURN QUERY SELECT true, s.id, c_id, 'ok';
END;
$$;

-- Reserve one VIDEO (COUNT)
CREATE OR REPLACE FUNCTION fn_reserve_video(p_user_id uuid, p_session_id uuid)
RETURNS TABLE(ok boolean, subscription_id uuid, consumption_id uuid, msg text)
LANGUAGE plpgsql
AS $$
DECLARE
  s user_subscriptions;
  u subscription_usage;
  c_id uuid;
BEGIN
  SELECT *
    INTO s
  FROM v_active_user_subscriptions
  WHERE user_id = p_user_id
  ORDER BY current_period_end DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, 'no_active_subscription';
    RETURN;
  END IF;

  u := fn_current_usage(s.id);

  UPDATE subscription_usage
     SET consumed_videos = consumed_videos + 1,
         updated_at = now()
   WHERE id = u.id
     AND consumed_videos < included_videos
  RETURNING * INTO u;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, s.id, NULL::uuid, 'no_video_entitlement_left';
    RETURN;
  END IF;

  INSERT INTO entitlement_consumptions (
    id, subscription_id, session_id, consumption_type, amount, source, created_at
  ) VALUES (
    gen_random_uuid(), s.id, p_session_id, 'video', 1, 'system', now()
  ) RETURNING id INTO c_id;

  RETURN QUERY SELECT true, s.id, c_id, 'ok';
END;
$$;

-- Commit reservation (finalize)
CREATE OR REPLACE FUNCTION fn_commit_consumption(p_consumption_id uuid)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  c entitlement_consumptions;
BEGIN
  SELECT * INTO c FROM entitlement_consumptions WHERE id = p_consumption_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  UPDATE entitlement_consumptions
     SET finalized = true
   WHERE id = p_consumption_id;

  RETURN true;
END;
$$;

-- Release reservation (undo, e.g., canceled session)
CREATE OR REPLACE FUNCTION fn_release_consumption(p_consumption_id uuid)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  c entitlement_consumptions;
  s user_subscriptions;
  u subscription_usage;
BEGIN
  SELECT * INTO c FROM entitlement_consumptions WHERE id = p_consumption_id FOR UPDATE;
  IF NOT FOUND OR c.finalized THEN
    RETURN false;
  END IF;

  SELECT * INTO s FROM user_subscriptions WHERE id = c.subscription_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  u := fn_current_usage(s.id);

  IF c.consumption_type = 'chat' THEN
     UPDATE subscription_usage
        SET consumed_chats = GREATEST(consumed_chats - c.amount, 0),
            updated_at = now()
      WHERE id = u.id;
  ELSIF c.consumption_type = 'video' THEN
     UPDATE subscription_usage
        SET consumed_videos = GREATEST(consumed_videos - c.amount, 0),
            updated_at = now()
      WHERE id = u.id;
  END IF;

  UPDATE entitlement_consumptions
     SET canceled_at = now()
   WHERE id = p_consumption_id;

  RETURN true;
END;
$$;

-- ============================================================
-- RLS (Supabase starter policies)
-- ============================================================

-- Helper: is current JWT an admin?
CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM users WHERE id = auth.uid() AND role = 'admin'
  );
$$;

-- Enable RLS
ALTER TABLE users                      ENABLE ROW LEVEL SECURITY;
ALTER TABLE pets                       ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_sessions              ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE consultation_notes         ENABLE ROW LEVEL SECURITY;
ALTER TABLE care_plans                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE ratings                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_subscriptions         ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscription_usage         ENABLE ROW LEVEL SECURITY;
ALTER TABLE entitlement_consumptions   ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE billing_profiles           ENABLE ROW LEVEL SECURITY;

-- Users
CREATE POLICY users_self_select ON users
  FOR SELECT USING (id = auth.uid() OR is_admin());
CREATE POLICY users_self_update ON users
  FOR UPDATE USING (id = auth.uid() OR is_admin());

-- Pets (owner/admin)
CREATE POLICY pets_owner_rw ON pets
  FOR ALL USING (user_id = auth.uid() OR is_admin());

-- Chat sessions (participants/admin)
CREATE POLICY chat_sessions_participants ON chat_sessions
  FOR SELECT USING (
    user_id = auth.uid() OR vet_id = auth.uid() OR is_admin()
  );
CREATE POLICY chat_sessions_create_user ON chat_sessions
  FOR INSERT WITH CHECK (user_id = auth.uid() OR is_admin());
CREATE POLICY chat_sessions_update_participant ON chat_sessions
  FOR UPDATE USING (user_id = auth.uid() OR vet_id = auth.uid() OR is_admin());

-- Messages (sender or participant/admin)
CREATE POLICY messages_rw ON messages
  FOR ALL USING (
    sender_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM chat_sessions s
      WHERE s.id = messages.session_id
        AND (s.user_id = auth.uid() OR s.vet_id = auth.uid())
    )
    OR is_admin()
  );

-- Notes & Care plans (owner/vet/admin)
CREATE POLICY notes_view ON consultation_notes
  FOR SELECT USING (
    vet_id = auth.uid()
    OR EXISTS (SELECT 1 FROM pets p WHERE p.id = consultation_notes.pet_id AND p.user_id = auth.uid())
    OR is_admin()
  );
CREATE POLICY care_plans_view ON care_plans
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM pets p WHERE p.id = care_plans.pet_id AND p.user_id = auth.uid())
    OR is_admin()
  );

-- Ratings (participants/admin)
CREATE POLICY ratings_rw ON ratings
  FOR ALL USING (
    user_id = auth.uid()
    OR vet_id = auth.uid()
    OR is_admin()
  );

-- Subscriptions & usage & consumptions (owner/admin)
CREATE POLICY subs_owner_view ON user_subscriptions
  FOR SELECT USING (user_id = auth.uid() OR is_admin());
CREATE POLICY usage_owner_view ON subscription_usage
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM user_subscriptions s WHERE s.id = subscription_usage.subscription_id AND s.user_id = auth.uid())
    OR is_admin()
  );
CREATE POLICY consumptions_owner_view ON entitlement_consumptions
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM user_subscriptions s WHERE s.id = entitlement_consumptions.subscription_id AND s.user_id = auth.uid())
    OR is_admin()
  );

-- Payments & Billing profiles (owner/admin)
CREATE POLICY payments_owner_view ON payments
  FOR SELECT USING (user_id = auth.uid() OR is_admin());
CREATE POLICY billing_profiles_owner_rw ON billing_profiles
  FOR ALL USING (user_id = auth.uid() OR is_admin());

-- ============================================================
-- NOTES
-- - Run ANALYZE after populating embeddings for optimal IVFFLAT recall.
-- - Pets “seats” are plan.default `pets_included_default` with optional
--   per-subscription override `pets_included`.
-- - Entitlements are COUNT-based for chat/video.
-- ============================================================
