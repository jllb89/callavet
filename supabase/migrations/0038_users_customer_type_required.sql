-- 0038_users_customer_type_required.sql
-- Add required customer_type classification for users and include it in search_tsv.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS customer_type text;

UPDATE public.users
SET customer_type = coalesce(customer_type, 'owner')
WHERE customer_type IS NULL;

ALTER TABLE public.users
  ALTER COLUMN customer_type SET DEFAULT 'owner',
  ALTER COLUMN customer_type SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'users_customer_type_check'
  ) THEN
    ALTER TABLE public.users
      ADD CONSTRAINT users_customer_type_check
      CHECK (customer_type IN ('owner', 'caballerango', 'veterinarian', 'trainer', 'ranch_responsible'));
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.trg_users_search_tsv_only()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  txt text;
BEGIN
  txt := coalesce(NEW.full_name, '') || ' ' ||
         coalesce(NEW.email, '') || ' ' ||
         coalesce(NEW.phone, '') || ' ' ||
         coalesce(NEW.customer_type, '');

  NEW.search_tsv := public.es_en_tsv(txt);
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DO $$
DECLARE
  expr text;
BEGIN
  SELECT generation_expression
    INTO expr
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'users'
    AND column_name = 'search_tsv';

  IF expr IS NOT NULL THEN
    ALTER TABLE public.users DROP COLUMN IF EXISTS search_tsv;

    ALTER TABLE public.users
      ADD COLUMN search_tsv tsvector;
  END IF;

  CREATE INDEX IF NOT EXISTS users_tsv_gin ON public.users USING GIN (search_tsv);
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'users'
      AND t.tgname = 'trg_users_search_tsv'
  ) THEN
    DROP TRIGGER trg_users_search_tsv ON public.users;
  END IF;

  CREATE TRIGGER trg_users_search_tsv
  BEFORE INSERT OR UPDATE OF email, full_name, phone, customer_type
  ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_users_search_tsv_only();
END $$;

UPDATE public.users
SET
  updated_at = now(),
  search_tsv = public.es_en_tsv(
    coalesce(full_name, '') || ' ' ||
    coalesce(email, '') || ' ' ||
    coalesce(phone, '') || ' ' ||
    coalesce(customer_type, '')
  );