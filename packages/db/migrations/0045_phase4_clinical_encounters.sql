-- Mirror migration for package/db tooling.
-- See supabase/migrations/0045_phase4_clinical_encounters.sql

BEGIN;

CREATE TABLE IF NOT EXISTS public.clinical_encounters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid UNIQUE REFERENCES public.chat_sessions(id) ON DELETE SET NULL,
  appointment_id uuid REFERENCES public.appointments(id) ON DELETE SET NULL,
  pet_id uuid NOT NULL REFERENCES public.pets(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  vet_id uuid REFERENCES public.vets(id) ON DELETE SET NULL,
  video_room_id text,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
  started_at timestamptz NOT NULL DEFAULT now(),
  ended_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT clinical_encounters_end_after_start CHECK (ended_at IS NULL OR ended_at >= started_at)
);

CREATE INDEX IF NOT EXISTS clinical_encounters_pet_idx ON public.clinical_encounters (pet_id, created_at DESC);
CREATE INDEX IF NOT EXISTS clinical_encounters_user_idx ON public.clinical_encounters (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS clinical_encounters_vet_idx ON public.clinical_encounters (vet_id, created_at DESC);
CREATE INDEX IF NOT EXISTS clinical_encounters_session_idx ON public.clinical_encounters (session_id);
CREATE INDEX IF NOT EXISTS clinical_encounters_appointment_idx ON public.clinical_encounters (appointment_id);

ALTER TABLE public.clinical_encounters ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_policies
     WHERE schemaname = current_schema()
       AND tablename = 'clinical_encounters'
       AND policyname = 'clinical_encounters_select_actor'
  ) THEN
    CREATE POLICY clinical_encounters_select_actor ON public.clinical_encounters
      FOR SELECT
      USING (
        user_id = auth.uid()
        OR vet_id = auth.uid()
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
       AND tablename = 'clinical_encounters'
       AND policyname = 'clinical_encounters_insert_actor'
  ) THEN
    CREATE POLICY clinical_encounters_insert_actor ON public.clinical_encounters
      FOR INSERT
      WITH CHECK (
        user_id = auth.uid()
        OR vet_id = auth.uid()
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
       AND tablename = 'clinical_encounters'
       AND policyname = 'clinical_encounters_update_actor'
  ) THEN
    CREATE POLICY clinical_encounters_update_actor ON public.clinical_encounters
      FOR UPDATE
      USING (
        user_id = auth.uid()
        OR vet_id = auth.uid()
        OR is_admin()
      )
      WITH CHECK (
        user_id = auth.uid()
        OR vet_id = auth.uid()
        OR is_admin()
      );
  END IF;
END$$;

ALTER TABLE public.consultation_notes ADD COLUMN IF NOT EXISTS encounter_id uuid;
ALTER TABLE public.image_cases ADD COLUMN IF NOT EXISTS encounter_id uuid;
ALTER TABLE public.care_plans ADD COLUMN IF NOT EXISTS encounter_id uuid;

DO $$ BEGIN
  ALTER TABLE public.consultation_notes
    ADD CONSTRAINT consultation_notes_encounter_id_fkey
    FOREIGN KEY (encounter_id) REFERENCES public.clinical_encounters(id) ON DELETE SET NULL;
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_table THEN NULL;
END $$;

DO $$ BEGIN
  ALTER TABLE public.image_cases
    ADD CONSTRAINT image_cases_encounter_id_fkey
    FOREIGN KEY (encounter_id) REFERENCES public.clinical_encounters(id) ON DELETE SET NULL;
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_table THEN NULL;
END $$;

DO $$ BEGIN
  ALTER TABLE public.care_plans
    ADD CONSTRAINT care_plans_encounter_id_fkey
    FOREIGN KEY (encounter_id) REFERENCES public.clinical_encounters(id) ON DELETE SET NULL;
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_table THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS consultation_notes_encounter_idx ON public.consultation_notes (encounter_id, created_at DESC);
CREATE INDEX IF NOT EXISTS image_cases_encounter_idx ON public.image_cases (encounter_id, created_at DESC);
CREATE INDEX IF NOT EXISTS care_plans_encounter_idx ON public.care_plans (encounter_id, created_at DESC);

INSERT INTO public.clinical_encounters (session_id, appointment_id, pet_id, user_id, vet_id, status, started_at, created_at)
SELECT
  s.id,
  a.id,
  COALESCE(s.pet_id, n.pet_id, i.pet_id) AS pet_id,
  s.user_id,
  s.vet_id,
  CASE WHEN s.status = 'completed' THEN 'closed' ELSE 'open' END AS status,
  COALESCE(s.started_at, s.created_at, now()) AS started_at,
  now() AS created_at
FROM public.chat_sessions s
LEFT JOIN public.appointments a ON a.session_id = s.id
LEFT JOIN LATERAL (
  SELECT cn.pet_id
    FROM public.consultation_notes cn
   WHERE cn.session_id = s.id
   ORDER BY cn.created_at ASC
   LIMIT 1
) n ON TRUE
LEFT JOIN LATERAL (
  SELECT ic.pet_id
    FROM public.image_cases ic
   WHERE ic.session_id = s.id
   ORDER BY ic.created_at ASC
   LIMIT 1
) i ON TRUE
WHERE COALESCE(s.pet_id, n.pet_id, i.pet_id) IS NOT NULL
ON CONFLICT (session_id) DO NOTHING;

UPDATE public.consultation_notes cn
   SET encounter_id = ce.id
  FROM public.clinical_encounters ce
 WHERE cn.encounter_id IS NULL
   AND ce.session_id = cn.session_id
   AND ce.pet_id = cn.pet_id;

UPDATE public.image_cases ic
   SET encounter_id = ce.id
  FROM public.clinical_encounters ce
 WHERE ic.encounter_id IS NULL
   AND ce.session_id = ic.session_id
   AND ce.pet_id = ic.pet_id;

UPDATE public.care_plans cp
   SET encounter_id = (
     SELECT x.id
       FROM public.clinical_encounters x
      WHERE x.pet_id = cp.pet_id
      ORDER BY x.created_at DESC
      LIMIT 1
   )
 WHERE cp.encounter_id IS NULL;

CREATE OR REPLACE FUNCTION public.ensure_clinical_encounter(p_session_id uuid, p_pet_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_session record;
  v_pet_id uuid;
BEGIN
  IF p_session_id IS NOT NULL THEN
    SELECT id INTO v_id
      FROM public.clinical_encounters
     WHERE session_id = p_session_id
     LIMIT 1;
    IF v_id IS NOT NULL THEN
      RETURN v_id;
    END IF;
  END IF;

  IF p_session_id IS NULL AND p_pet_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_session_id IS NOT NULL THEN
    SELECT s.id,
           s.user_id,
           s.vet_id,
           s.pet_id,
           s.started_at,
           s.created_at,
           s.status,
           a.id AS appointment_id
      INTO v_session
      FROM public.chat_sessions s
 LEFT JOIN public.appointments a ON a.session_id = s.id
     WHERE s.id = p_session_id
     LIMIT 1;

    IF v_session.id IS NULL THEN
      RETURN NULL;
    END IF;

    v_pet_id := COALESCE(p_pet_id, v_session.pet_id);
    IF v_pet_id IS NULL THEN
      RETURN NULL;
    END IF;

    INSERT INTO public.clinical_encounters (
      session_id,
      appointment_id,
      pet_id,
      user_id,
      vet_id,
      status,
      started_at,
      created_at,
      updated_at
    )
    VALUES (
      p_session_id,
      v_session.appointment_id,
      v_pet_id,
      v_session.user_id,
      v_session.vet_id,
      CASE WHEN v_session.status = 'completed' THEN 'closed' ELSE 'open' END,
      COALESCE(v_session.started_at, v_session.created_at, now()),
      now(),
      now()
    )
    ON CONFLICT (session_id) DO UPDATE
       SET pet_id = COALESCE(public.clinical_encounters.pet_id, EXCLUDED.pet_id),
           appointment_id = COALESCE(public.clinical_encounters.appointment_id, EXCLUDED.appointment_id),
           updated_at = now()
    RETURNING id INTO v_id;

    RETURN v_id;
  END IF;

  SELECT id
    INTO v_id
    FROM public.clinical_encounters
   WHERE session_id IS NULL
     AND pet_id = p_pet_id
   ORDER BY created_at DESC
   LIMIT 1;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  INSERT INTO public.clinical_encounters (
    pet_id,
    user_id,
    vet_id,
    status,
    started_at,
    created_at,
    updated_at
  )
  SELECT
    p.id,
    p.user_id,
    NULL,
    'open',
    now(),
    now(),
    now()
  FROM public.pets p
  WHERE p.id = p_pet_id
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.ensure_clinical_encounter(uuid, uuid) TO authenticated;

COMMIT;
