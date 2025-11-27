-- Messages soft deletion & redaction support
-- Adds columns; safe to rerun with IF NOT EXISTS guards

ALTER TABLE messages
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
  ADD COLUMN IF NOT EXISTS redacted_at timestamptz,
  ADD COLUMN IF NOT EXISTS redaction_reason text,
  ADD COLUMN IF NOT EXISTS redacted_original_content text;

-- Optional future: trigger to null search_tsv when deleted/redacted.
-- For now controllers will set search_tsv = NULL when performing these actions.
