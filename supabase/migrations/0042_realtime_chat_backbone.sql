-- Phase 2 realtime chat backbone: idempotency, ordering, and receipts.

ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS client_key text,
  ADD COLUMN IF NOT EXISTS stream_order bigint,
  ADD COLUMN IF NOT EXISTS edited_at timestamptz;

CREATE SEQUENCE IF NOT EXISTS public.messages_stream_order_seq;

ALTER SEQUENCE public.messages_stream_order_seq
  OWNED BY public.messages.stream_order;

ALTER TABLE public.messages
  ALTER COLUMN stream_order SET DEFAULT nextval('public.messages_stream_order_seq');

UPDATE public.messages
SET stream_order = nextval('public.messages_stream_order_seq')
WHERE stream_order IS NULL;

ALTER TABLE public.messages
  ALTER COLUMN stream_order SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS messages_stream_order_unique
  ON public.messages (stream_order);

CREATE UNIQUE INDEX IF NOT EXISTS messages_session_client_key_unique
  ON public.messages (session_id, client_key)
  WHERE client_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS messages_session_stream_order_idx
  ON public.messages (session_id, stream_order);

CREATE TABLE IF NOT EXISTS public.message_receipts (
  message_id uuid NOT NULL REFERENCES public.messages(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  delivered_at timestamptz NOT NULL DEFAULT now(),
  read_at timestamptz,
  PRIMARY KEY (message_id, user_id)
);

CREATE INDEX IF NOT EXISTS message_receipts_user_idx
  ON public.message_receipts (user_id, delivered_at desc);

CREATE INDEX IF NOT EXISTS message_receipts_message_read_idx
  ON public.message_receipts (message_id, read_at);

ALTER TABLE public.message_receipts ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename = 'message_receipts'
       AND policyname = 'message_receipts_participants_rw'
  ) THEN
    CREATE POLICY message_receipts_participants_rw ON public.message_receipts
      FOR ALL
      USING (
        EXISTS (
          SELECT 1
            FROM public.messages m
            JOIN public.chat_sessions s ON s.id = m.session_id
           WHERE m.id = message_receipts.message_id
             AND (s.user_id = auth.uid() OR s.vet_id = auth.uid())
        )
        OR is_admin()
      )
      WITH CHECK (
        EXISTS (
          SELECT 1
            FROM public.messages m
            JOIN public.chat_sessions s ON s.id = m.session_id
           WHERE m.id = message_receipts.message_id
             AND (s.user_id = auth.uid() OR s.vet_id = auth.uid())
        )
        OR is_admin()
      );
  END IF;
END $$;