-- ============================================================
-- 0008_horse_phase_seed.sql
-- Minimal, idempotent seed for Phase 1 (horses only)
-- - Uses fixed UUIDs where helpful for deterministic references
-- - Safe to run multiple times (ON CONFLICT / IF NOT EXISTS patterns)
-- - Removes prior dog sample from helpers seed
-- ============================================================

-- ============================================================
-- Clean-up: remove prior dog sample pet from helpers/seed.sql
-- ============================================================
-- Remove only the known helper-seed dog row if present
DELETE FROM pets WHERE id = '11111111-1111-1111-1111-111111111111';

-- (Optional safety) If you want horses-only for Phase 1, you could also
-- delete non-equine pets that were created manually. Commented by default.
-- -- DELETE FROM pets WHERE species IS NOT NULL AND lower(species) <> 'equine';

-- ============================================================
-- Users (admin, test user, vet) — fixed ids for observability
-- ============================================================
-- Admin user (for admin-gated routes and visibility)
INSERT INTO users (id, email, full_name, phone, role, is_verified)
VALUES ('00000000-0000-0000-0000-000000000001','admin@callavet.mx','Admin','', 'admin', true)
ON CONFLICT (id) DO NOTHING;

-- Test User (used by Observability when no Bearer is provided)
INSERT INTO users (id, email, full_name, phone, role, is_verified)
VALUES ('00000000-0000-0000-0000-000000000002','user@callavet.mx','Test User','+52...', 'user', true)
ON CONFLICT (id) DO NOTHING;

-- Test Vet (equine)
INSERT INTO users (id, email, full_name, phone, role, is_verified)
VALUES ('00000000-0000-0000-0000-000000000003','vet@callavet.mx','Test Vet','+52...', 'vet', true)
ON CONFLICT (id) DO NOTHING;

-- Ensure vet profile row for Test Vet (equine GP)
INSERT INTO vets (id, license_number, country, bio, years_experience, is_approved, specialties, languages)
VALUES ('00000000-0000-0000-0000-000000000003','MX-12345','MX','Equine-first GP vet',8,true,ARRAY[]::uuid[],ARRAY['es','en'])
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- Plans (keep small catalog) — idempotent on code
-- ============================================================
-- Starter plan (horses)
INSERT INTO subscription_plans (
  id, code, name, description, price_cents, billing_period,
  included_chats, included_videos, pets_included_default, tax_rate, currency, is_active
) VALUES (
  gen_random_uuid(),'starter','Starter','2 chats equinos / mes',19900,'month',2,0,1,0.16,'MXN',true
)
ON CONFLICT (code) DO NOTHING;

-- Plus plan (horses)
INSERT INTO subscription_plans (
  id, code, name, description, price_cents, billing_period,
  included_chats, included_videos, pets_included_default, tax_rate, currency, is_active
) VALUES (
  gen_random_uuid(),'plus','Plus','2 chats + 1 video (equinos)',34900,'month',2,1,2,0.16,'MXN',true
)
ON CONFLICT (code) DO NOTHING;

-- ============================================================
-- Attach active subscription for Test User (plus) and ensure usage
-- ============================================================
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

  -- Insert active subscription for current 30-day period if none exists for user
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
    -- Ensure usage exists for most recent active subscription
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

-- ============================================================
-- Pets (horses only)
-- ============================================================
-- Primary horse for Test User
INSERT INTO pets (id, user_id, name, species, breed, sex, weight_kg, medical_notes)
VALUES ('22222222-2222-2222-2222-222222222222','00000000-0000-0000-0000-000000000002','Estrella','equine','Criollo','F',420,'Sensibilidad digestiva')
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- Vet Care Center (equine)
-- ============================================================
INSERT INTO vet_care_centers (id, name, address, phone, website, is_partner)
VALUES ('33333333-3333-3333-3333-333333333333','Hospital Equino Roma','CDMX','+52...','https://example.mx',true)
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- Knowledge Base (equine example)
-- ============================================================
INSERT INTO kb_items (id, title, body, species, tags, version, created_by)
VALUES (
  '44444444-4444-4444-4444-444444444444',
  'Cólico equino: señales de alerta',
  'Si hay dolor intenso, sudoración, falta de respuesta a analgesia → derivar a hospital.',
  ARRAY['equine'], ARRAY['emergency','triage'], 1,
  '00000000-0000-0000-0000-000000000001'
)
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- Optional: One completed session for Test User (chat) referencing horse
-- ============================================================
-- Session row (completed)
INSERT INTO chat_sessions (id, user_id, pet_id, status, mode, started_at, ended_at)
VALUES ('55555555-5555-5555-5555-555555555555','00000000-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222','completed','chat', now() - interval '2 days', now() - interval '2 days' + interval '15 minutes')
ON CONFLICT (id) DO NOTHING;

-- Messages (minimal transcript)
INSERT INTO messages (id, session_id, sender_id, role, content, created_at)
VALUES
  ('66666666-6666-6666-6666-666666666660','55555555-5555-5555-5555-555555555555','00000000-0000-0000-0000-000000000002','user','Mi yegua muestra signos de cólico, ¿qué hago?', now() - interval '2 days'),
  ('66666666-6666-6666-6666-666666666661','55555555-5555-5555-5555-555555555555','00000000-0000-0000-0000-000000000003','vet','Retire el alimento, camínela suavemente y observe si mejora. Si empeora, acuda a hospital.', now() - interval '2 days' + interval '2 minutes')
ON CONFLICT (id) DO NOTHING;

-- Rating for the session (4/5)
INSERT INTO ratings (id, session_id, vet_id, user_id, score, comment)
VALUES ('77777777-7777-7777-7777-777777777777','55555555-5555-5555-5555-555555555555','00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000002',4,'Atención oportuna, gracias!')
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- Notes
-- - Seeds are minimal and horse-focused. Extend as new routes land (pets files, appointments, etc.).
-- - Avoid destructive changes in prod. This script only deletes the known helper dog id.
-- ============================================================
