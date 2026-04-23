BEGIN;

-- Structured horse health profile (1:1 with pet)
CREATE TABLE IF NOT EXISTS public.pet_health_profiles (
  pet_id uuid PRIMARY KEY REFERENCES public.pets(id) ON DELETE CASCADE,
  allergies text[] NOT NULL DEFAULT '{}'::text[],
  chronic_conditions text[] NOT NULL DEFAULT '{}'::text[],
  current_medications jsonb NOT NULL DEFAULT '[]'::jsonb,
  vaccine_history jsonb NOT NULL DEFAULT '[]'::jsonb,
  injury_history jsonb NOT NULL DEFAULT '[]'::jsonb,
  procedure_history jsonb NOT NULL DEFAULT '[]'::jsonb,
  feed_profile jsonb NOT NULL DEFAULT '{}'::jsonb,
  insurance jsonb NOT NULL DEFAULT '{}'::jsonb,
  emergency_contacts jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pet_health_profiles_current_medications_array CHECK (jsonb_typeof(current_medications) = 'array'),
  CONSTRAINT pet_health_profiles_vaccine_history_array CHECK (jsonb_typeof(vaccine_history) = 'array'),
  CONSTRAINT pet_health_profiles_injury_history_array CHECK (jsonb_typeof(injury_history) = 'array'),
  CONSTRAINT pet_health_profiles_procedure_history_array CHECK (jsonb_typeof(procedure_history) = 'array'),
  CONSTRAINT pet_health_profiles_feed_profile_object CHECK (jsonb_typeof(feed_profile) = 'object'),
  CONSTRAINT pet_health_profiles_insurance_object CHECK (jsonb_typeof(insurance) = 'object'),
  CONSTRAINT pet_health_profiles_emergency_contacts_array CHECK (jsonb_typeof(emergency_contacts) = 'array')
);

CREATE INDEX IF NOT EXISTS pet_health_profiles_allergies_gin ON public.pet_health_profiles USING gin (allergies);
CREATE INDEX IF NOT EXISTS pet_health_profiles_conditions_gin ON public.pet_health_profiles USING gin (chronic_conditions);

ALTER TABLE public.pet_health_profiles ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'pet_health_profiles'
      AND policyname = 'pet_health_profiles_select_actor'
  ) THEN
    CREATE POLICY pet_health_profiles_select_actor ON public.pet_health_profiles
      FOR SELECT
      USING (
        EXISTS (
          SELECT 1 FROM public.pets p
          WHERE p.id = pet_health_profiles.pet_id
            AND p.user_id = auth.uid()
        )
        OR EXISTS (
          SELECT 1
          FROM public.clinical_encounters ce
          WHERE ce.pet_id = pet_health_profiles.pet_id
            AND ce.vet_id = auth.uid()
        )
        OR is_admin()
      );
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'pet_health_profiles'
      AND policyname = 'pet_health_profiles_upsert_actor'
  ) THEN
    CREATE POLICY pet_health_profiles_upsert_actor ON public.pet_health_profiles
      FOR INSERT
      WITH CHECK (
        EXISTS (
          SELECT 1 FROM public.pets p
          WHERE p.id = pet_health_profiles.pet_id
            AND p.user_id = auth.uid()
        )
        OR is_admin()
      );
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'pet_health_profiles'
      AND policyname = 'pet_health_profiles_update_actor'
  ) THEN
    CREATE POLICY pet_health_profiles_update_actor ON public.pet_health_profiles
      FOR UPDATE
      USING (
        EXISTS (
          SELECT 1 FROM public.pets p
          WHERE p.id = pet_health_profiles.pet_id
            AND p.user_id = auth.uid()
        )
        OR is_admin()
      )
      WITH CHECK (
        EXISTS (
          SELECT 1 FROM public.pets p
          WHERE p.id = pet_health_profiles.pet_id
            AND p.user_id = auth.uid()
        )
        OR is_admin()
      );
  END IF;
END$$;

INSERT INTO public.pet_health_profiles (pet_id)
SELECT p.id
FROM public.pets p
ON CONFLICT (pet_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.trg_pet_health_profiles_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pet_health_profiles_set_updated_at ON public.pet_health_profiles;
CREATE TRIGGER trg_pet_health_profiles_set_updated_at
BEFORE UPDATE ON public.pet_health_profiles
FOR EACH ROW
EXECUTE FUNCTION public.trg_pet_health_profiles_set_updated_at();

-- Structured consultation note fields
ALTER TABLE public.consultation_notes ADD COLUMN IF NOT EXISTS assessment_text text;
ALTER TABLE public.consultation_notes ADD COLUMN IF NOT EXISTS diagnosis_text text;
ALTER TABLE public.consultation_notes ADD COLUMN IF NOT EXISTS follow_up_instructions text;
ALTER TABLE public.consultation_notes ADD COLUMN IF NOT EXISTS next_follow_up_at timestamptz;
ALTER TABLE public.consultation_notes ADD COLUMN IF NOT EXISTS severity text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'consultation_notes_severity_check'
  ) THEN
    ALTER TABLE public.consultation_notes
      ADD CONSTRAINT consultation_notes_severity_check
      CHECK (severity IS NULL OR severity IN ('low', 'medium', 'high', 'critical'));
  END IF;
END$$;

CREATE INDEX IF NOT EXISTS consultation_notes_severity_idx
  ON public.consultation_notes (severity) WHERE severity IS NOT NULL;
CREATE INDEX IF NOT EXISTS consultation_notes_follow_up_idx
  ON public.consultation_notes (next_follow_up_at) WHERE next_follow_up_at IS NOT NULL;

-- Encounter-linked file artifacts
CREATE TABLE IF NOT EXISTS public.encounter_files (
  id uuid PRIMARY KEY,
  encounter_id uuid NOT NULL REFERENCES public.clinical_encounters(id) ON DELETE CASCADE,
  pet_id uuid NOT NULL REFERENCES public.pets(id) ON DELETE CASCADE,
  session_id uuid REFERENCES public.chat_sessions(id) ON DELETE SET NULL,
  uploaded_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  storage_path text NOT NULL,
  content_type text,
  labels text[] NOT NULL DEFAULT '{}'::text[],
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (encounter_id, storage_path)
);

CREATE INDEX IF NOT EXISTS encounter_files_encounter_idx ON public.encounter_files (encounter_id, created_at DESC);
CREATE INDEX IF NOT EXISTS encounter_files_pet_idx ON public.encounter_files (pet_id, created_at DESC);

ALTER TABLE public.encounter_files ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'encounter_files'
      AND policyname = 'encounter_files_select_actor'
  ) THEN
    CREATE POLICY encounter_files_select_actor ON public.encounter_files
      FOR SELECT
      USING (
        EXISTS (
          SELECT 1
          FROM public.clinical_encounters ce
          WHERE ce.id = encounter_files.encounter_id
            AND (ce.user_id = auth.uid() OR ce.vet_id = auth.uid())
        )
        OR is_admin()
      );
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'encounter_files'
      AND policyname = 'encounter_files_insert_actor'
  ) THEN
    CREATE POLICY encounter_files_insert_actor ON public.encounter_files
      FOR INSERT
      WITH CHECK (
        EXISTS (
          SELECT 1
          FROM public.clinical_encounters ce
          WHERE ce.id = encounter_files.encounter_id
            AND (ce.user_id = auth.uid() OR ce.vet_id = auth.uid())
        )
        OR is_admin()
      );
  END IF;
END$$;

COMMIT;
