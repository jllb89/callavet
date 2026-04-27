-- ============================================================
-- 0048: Phase 3 LiveKit Webhook Events
-- ============================================================
-- Persists LiveKit room and participant lifecycle events so video
-- session state can be replayed and audited.

BEGIN;

CREATE TABLE IF NOT EXISTS public.livekit_video_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL DEFAULT 'livekit' CHECK (provider = 'livekit'),
  event_type text NOT NULL,
  room_name text,
  room_sid text,
  session_id uuid REFERENCES public.chat_sessions(id) ON DELETE SET NULL,
  participant_identity text,
  participant_sid text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  processing_error text
);

CREATE INDEX IF NOT EXISTS livekit_video_events_session_idx ON public.livekit_video_events (session_id, received_at DESC);
CREATE INDEX IF NOT EXISTS livekit_video_events_room_idx ON public.livekit_video_events (room_name, received_at DESC);
CREATE INDEX IF NOT EXISTS livekit_video_events_type_idx ON public.livekit_video_events (event_type, received_at DESC);

ALTER TABLE public.livekit_video_events ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename = 'livekit_video_events'
       AND policyname = 'livekit_video_events_select_actor'
  ) THEN
    CREATE POLICY livekit_video_events_select_actor ON public.livekit_video_events
      FOR SELECT
      USING (
        public.is_admin()
        OR EXISTS (
          SELECT 1
            FROM public.chat_sessions s
           WHERE s.id = livekit_video_events.session_id
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
       AND tablename = 'livekit_video_events'
       AND policyname = 'livekit_video_events_admin_all'
  ) THEN
    CREATE POLICY livekit_video_events_admin_all ON public.livekit_video_events
      FOR ALL
      USING (public.is_admin())
      WITH CHECK (public.is_admin());
  END IF;
END $$;

COMMIT;
