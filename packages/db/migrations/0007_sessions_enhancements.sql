-- Sessions enhancements: add mode and helpful indexes
-- Safe to run multiple times due to IF NOT EXISTS

ALTER TABLE chat_sessions
  ADD COLUMN IF NOT EXISTS mode text CHECK (mode IN ('chat','video'));

-- Backfill NULLs to default 'chat' to align with current usage
UPDATE chat_sessions SET mode = 'chat' WHERE mode IS NULL;

-- Optional: ensure helpful listing order performance
DO $$
BEGIN
  BEGIN
    CREATE INDEX IF NOT EXISTS chat_sessions_started_created_idx ON chat_sessions (started_at DESC NULLS LAST, created_at DESC);
  EXCEPTION WHEN duplicate_object THEN
    -- ignore
  END;
  BEGIN
    CREATE INDEX IF NOT EXISTS chat_sessions_user_vet_idx ON chat_sessions (user_id, vet_id);
  EXCEPTION WHEN duplicate_object THEN
    -- ignore
  END;
END$$;
