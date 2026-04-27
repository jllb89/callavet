-- ============================================================
-- 0049: Phase 3 Video Lifecycle Safety
-- ============================================================
-- Tracks LiveKit room lifecycle state and makes entitlement
-- commit/release idempotent for retries, forced end, and sweeps.

BEGIN;

CREATE TABLE IF NOT EXISTS public.video_session_lifecycle (
  session_id uuid PRIMARY KEY REFERENCES public.chat_sessions(id) ON DELETE CASCADE,
  room_name text,
  room_sid text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'waiting', 'live', 'ended', 'released', 'timed_out', 'host_absent', 'forced_ended')),
  first_room_started_at timestamptz,
  first_participant_joined_at timestamptz,
  owner_joined_at timestamptz,
  host_joined_at timestamptz,
  first_both_joined_at timestamptz,
  last_participant_left_at timestamptz,
  room_finished_at timestamptz,
  forced_end_at timestamptz,
  entitlement_consumption_id uuid REFERENCES public.entitlement_consumptions(id) ON DELETE SET NULL,
  entitlement_finalized_at timestamptz,
  entitlement_released_at timestamptz,
  safety_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS video_session_lifecycle_room_name_unique
  ON public.video_session_lifecycle (room_name)
  WHERE room_name IS NOT NULL;

CREATE INDEX IF NOT EXISTS video_session_lifecycle_status_idx
  ON public.video_session_lifecycle (status, updated_at DESC);

CREATE INDEX IF NOT EXISTS video_session_lifecycle_safety_idx
  ON public.video_session_lifecycle (first_both_joined_at, first_participant_joined_at, first_room_started_at, created_at)
  WHERE status IN ('pending', 'waiting');

ALTER TABLE public.video_session_lifecycle ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename = 'video_session_lifecycle'
       AND policyname = 'video_session_lifecycle_select_actor'
  ) THEN
    CREATE POLICY video_session_lifecycle_select_actor ON public.video_session_lifecycle
      FOR SELECT
      USING (
        is_admin()
        OR EXISTS (
          SELECT 1
            FROM public.chat_sessions s
           WHERE s.id = video_session_lifecycle.session_id
             AND (s.user_id = auth.uid() OR s.vet_id = auth.uid())
        )
      );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename = 'video_session_lifecycle'
       AND policyname = 'video_session_lifecycle_admin_all'
  ) THEN
    CREATE POLICY video_session_lifecycle_admin_all ON public.video_session_lifecycle
      FOR ALL
      USING (is_admin())
      WITH CHECK (is_admin());
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.fn_commit_consumption(p_consumption_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  c entitlement_consumptions;
BEGIN
  SELECT * INTO c FROM entitlement_consumptions WHERE id = p_consumption_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF c.canceled_at IS NOT NULL THEN
    RETURN false;
  END IF;

  IF c.finalized THEN
    RETURN true;
  END IF;

  UPDATE entitlement_consumptions
     SET finalized = true
   WHERE id = p_consumption_id
     AND canceled_at IS NULL;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_release_consumption(p_consumption_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  c entitlement_consumptions;
  s user_subscriptions;
  u subscription_usage;
BEGIN
  SELECT * INTO c FROM entitlement_consumptions WHERE id = p_consumption_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF c.finalized THEN
    RETURN false;
  END IF;

  IF c.canceled_at IS NOT NULL THEN
    RETURN true;
  END IF;

  IF coalesce(c.source, 'system') = 'system' THEN
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
  END IF;

  UPDATE entitlement_consumptions
     SET canceled_at = now()
   WHERE id = p_consumption_id
     AND canceled_at IS NULL;

  RETURN true;
END;
$$;

COMMIT;
