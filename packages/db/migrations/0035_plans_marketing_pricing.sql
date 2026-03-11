-- 0035_plans_marketing_pricing.sql
-- Production-safe enhancement for legacy public.plans catalog used by landing/admin tooling.
-- Keeps code as stable plan slug and adds structured marketing copy + monthly/yearly prices.

ALTER TABLE public.plans
  ADD COLUMN IF NOT EXISTS description jsonb,
  ADD COLUMN IF NOT EXISTS price_monthly_cents integer,
  ADD COLUMN IF NOT EXISTS price_annual_cents integer,
  ADD COLUMN IF NOT EXISTS currency text DEFAULT 'MXN',
  ADD COLUMN IF NOT EXISTS is_active boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS search_tsv tsvector,
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'plans_price_monthly_cents_nonneg'
  ) THEN
    ALTER TABLE public.plans
      ADD CONSTRAINT plans_price_monthly_cents_nonneg
      CHECK (price_monthly_cents IS NULL OR price_monthly_cents >= 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'plans_price_annual_cents_nonneg'
  ) THEN
    ALTER TABLE public.plans
      ADD CONSTRAINT plans_price_annual_cents_nonneg
      CHECK (price_annual_cents IS NULL OR price_annual_cents >= 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'plans_description_is_object'
  ) THEN
    ALTER TABLE public.plans
      ADD CONSTRAINT plans_description_is_object
      CHECK (description IS NULL OR jsonb_typeof(description) = 'object');
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS plans_tsv_gin ON public.plans USING GIN (search_tsv);
CREATE INDEX IF NOT EXISTS plans_active_idx ON public.plans (is_active);

CREATE OR REPLACE FUNCTION public.trg_plans_touch_and_tsv()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  txt text;
BEGIN
  txt := concat_ws(' ',
    coalesce(NEW.code, ''),
    coalesce(NEW.name, ''),
    coalesce(NEW.description->>'main', ''),
    coalesce(NEW.description->>'value', ''),
    coalesce(NEW.description->>'result', ''),
    coalesce((
      SELECT string_agg(value, ' ')
      FROM jsonb_array_elements_text(coalesce(NEW.description->'included', '[]'::jsonb)) AS value
    ), '')
  );

  NEW.search_tsv := public.es_en_tsv(txt);
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DO $$
BEGIN
  BEGIN
    CREATE TRIGGER trg_plans_touch_and_tsv
    BEFORE INSERT OR UPDATE OF code, name, description
    ON public.plans
    FOR EACH ROW
    EXECUTE FUNCTION public.trg_plans_touch_and_tsv();
  EXCEPTION WHEN duplicate_object THEN
    NULL;
  END;
END $$;

UPDATE public.plans
SET
  updated_at = now(),
  search_tsv = public.es_en_tsv(
    concat_ws(' ',
      coalesce(code, ''),
      coalesce(name, ''),
      coalesce(description->>'main', ''),
      coalesce(description->>'value', ''),
      coalesce(description->>'result', ''),
      coalesce((
        SELECT string_agg(value, ' ')
        FROM jsonb_array_elements_text(coalesce(description->'included', '[]'::jsonb)) AS value
      ), '')
    )
  );
