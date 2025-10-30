-- Seed (dev/staging only). Idempotent inserts.

-- Admin + test users
INSERT INTO users (id, email, full_name, phone, role, is_verified)
VALUES
  ('00000000-0000-0000-0000-000000000001','admin@callavet.mx','Admin','', 'admin', true),
  ('00000000-0000-0000-0000-000000000002','user@callavet.mx','Test User','+52...', 'user', true),
  ('00000000-0000-0000-0000-000000000003','vet@callavet.mx','Test Vet','+52...', 'vet', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO vets (id, license_number, country, bio, years_experience, is_approved, specialties, languages)
VALUES
  ('00000000-0000-0000-0000-000000000003','MX-12345','MX','Equine-first GP vet',8,true,ARRAY[]::uuid[],ARRAY['es','en'])
ON CONFLICT (id) DO NOTHING;

-- Subscription plans
INSERT INTO subscription_plans (id, code, name, description, price_cents, billing_period, included_chats, included_videos, pets_included_default, tax_rate, currency, is_active)
VALUES (gen_random_uuid(),'starter','Starter','2 chats al mes',19900,'month',2,0,1,0.16,'MXN',true)
ON CONFLICT (code) DO NOTHING;

INSERT INTO subscription_plans (id, code, name, description, price_cents, billing_period, included_chats, included_videos, pets_included_default, tax_rate, currency, is_active)
VALUES (gen_random_uuid(),'plus','Plus','2 chats + 1 video',34900,'month',2,1,2,0.16,'MXN',true)
ON CONFLICT (code) DO NOTHING;

INSERT INTO subscription_plans (id, code, name, description, price_cents, billing_period, included_chats, included_videos, pets_included_default, tax_rate, currency, is_active)
VALUES (gen_random_uuid(),'cuadra','Cuadra','4 chats + 2 videos',49900,'month',4,2,4,0.16,'MXN',true)
ON CONFLICT (code) DO NOTHING;

-- Vet specialties
INSERT INTO vet_specialties (id,name,description)
VALUES
  (gen_random_uuid(),'Equine GP','General practice for horses'),
  (gen_random_uuid(),'Surgery','Surgical procedures and pre/post op'),
  (gen_random_uuid(),'Dermatology','Skin conditions and allergies')
ON CONFLICT (id) DO NOTHING;

-- Knowledge base
INSERT INTO kb_items (id,title,body,species,tags,version,created_by)
VALUES
  (gen_random_uuid(),'Cólico equino: señales de alerta',
   'Si hay dolor intenso, sudoración, falta de respuesta a analgesia → derivar a hospital.',
   ARRAY['equine'], ARRAY['emergency','triage'], 1, '00000000-0000-0000-0000-000000000001')
ON CONFLICT (id) DO NOTHING;

-- Demo pet & center
INSERT INTO pets (id,user_id,name,species,breed,sex,weight_kg,medical_notes)
VALUES
  (gen_random_uuid(),'00000000-0000-0000-0000-000000000002','Estrella','equine','Criollo','F',420,'Sensibilidad digestiva')
ON CONFLICT (id) DO NOTHING;

INSERT INTO vet_care_centers (id,name,address,phone,website,is_partner)
VALUES
  (gen_random_uuid(),'Hospital Equino Roma','CDMX','+52...','https://example.mx',true)
ON CONFLICT (id) DO NOTHING;

-- Dev subscription for Test User (idempotent): attach PLUS plan and ensure usage row
DO $$
DECLARE
  v_user_id uuid := '00000000-0000-0000-0000-000000000002';
  v_plan_id uuid;
  v_sub_id uuid;
BEGIN
  SELECT id INTO v_plan_id FROM subscription_plans WHERE code = 'plus' LIMIT 1;
  IF v_plan_id IS NULL THEN
    RAISE NOTICE 'PLUS plan not found; skipping user subscription seed';
    RETURN;
  END IF;

  -- Insert active subscription for current 30-day period if none exists
  IF NOT EXISTS (
    SELECT 1 FROM user_subscriptions s
    WHERE s.user_id = v_user_id
      AND s.status IN ('trialing','active')
      AND now() >= s.current_period_start
      AND now() <  s.current_period_end
  ) THEN
    INSERT INTO user_subscriptions (
      id, user_id, plan_id, status, started_at,
      current_period_start, current_period_end, auto_renew, provider
    ) VALUES (
      gen_random_uuid(), v_user_id, v_plan_id, 'active', now(),
      date_trunc('day', now()), date_trunc('day', now()) + interval '30 days', true, 'stripe'
    ) RETURNING id INTO v_sub_id;

    -- Ensure period usage row exists
    PERFORM fn_current_usage(v_sub_id);
  ELSE
    -- Ensure usage exists for the most recent active subscription
    SELECT id INTO v_sub_id
    FROM v_active_user_subscriptions
    WHERE user_id = v_user_id
    ORDER BY current_period_end DESC
    LIMIT 1;
    IF v_sub_id IS NOT NULL THEN
      PERFORM fn_current_usage(v_sub_id);
    END IF;
  END IF;
END$$;
