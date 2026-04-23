-- Phase 1 vet operations: referrals, assignment primitives, and appointment lifecycle status expansion

DO $$
BEGIN
  ALTER TABLE appointments DROP CONSTRAINT IF EXISTS appointments_status_check;
EXCEPTION
  WHEN undefined_table THEN NULL;
END$$;

DO $$
BEGIN
  ALTER TABLE appointments
    ADD CONSTRAINT appointments_status_check CHECK (status IN ('scheduled','confirmed','active','completed','no_show','canceled'));
EXCEPTION
  WHEN duplicate_object THEN NULL;
END$$;

CREATE TABLE IF NOT EXISTS vet_referrals (
  id uuid PRIMARY KEY,
  pet_id uuid REFERENCES pets(id),
  user_id uuid REFERENCES users(id),
  specialty_id uuid REFERENCES vet_specialties(id),
  assigned_vet_id uuid REFERENCES vets(id),
  appointment_id uuid REFERENCES appointments(id),
  priority text NOT NULL DEFAULT 'routine' CHECK (priority IN ('routine', 'urgent')),
  status text NOT NULL DEFAULT 'intake' CHECK (status IN ('intake', 'assigned', 'accepted', 'completed', 'canceled')),
  notes text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS vet_referrals_user_idx ON vet_referrals (user_id, created_at desc);
CREATE INDEX IF NOT EXISTS vet_referrals_vet_idx ON vet_referrals (assigned_vet_id, created_at desc);
CREATE INDEX IF NOT EXISTS vet_referrals_specialty_idx ON vet_referrals (specialty_id, status);
CREATE INDEX IF NOT EXISTS vet_referrals_status_idx ON vet_referrals (status, created_at desc);

ALTER TABLE vet_referrals ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_policies
     WHERE schemaname = current_schema()
       AND tablename = 'vet_referrals'
       AND policyname = 'vet_referrals_select_actor'
  ) THEN
    CREATE POLICY vet_referrals_select_actor ON vet_referrals
      FOR SELECT
      USING (
        user_id = auth.uid()
        OR assigned_vet_id = auth.uid()
        OR is_admin()
      );
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_policies
     WHERE schemaname = current_schema()
       AND tablename = 'vet_referrals'
       AND policyname = 'vet_referrals_insert_owner'
  ) THEN
    CREATE POLICY vet_referrals_insert_owner ON vet_referrals
      FOR INSERT
      WITH CHECK (
        user_id = auth.uid()
        OR is_admin()
      );
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_policies
     WHERE schemaname = current_schema()
       AND tablename = 'vet_referrals'
       AND policyname = 'vet_referrals_update_actor'
  ) THEN
    CREATE POLICY vet_referrals_update_actor ON vet_referrals
      FOR UPDATE
      USING (
        user_id = auth.uid()
        OR assigned_vet_id = auth.uid()
        OR is_admin()
      );
  END IF;
END$$;