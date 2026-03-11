-- 0037_subscription_plans_marketing_finalize.sql
-- Finalize subscription_plans landing-content structure using ONLY local schema.
-- Safe to run after partial execution of 0036.

-- 1) Ensure columns exist (idempotent)
ALTER TABLE public.subscription_plans
  ADD COLUMN IF NOT EXISTS description_json jsonb,
  ADD COLUMN IF NOT EXISTS price_monthly_cents integer,
  ADD COLUMN IF NOT EXISTS price_annual_cents integer;

-- 2) Ensure constraints exist (idempotent)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'subscription_plans_description_json_is_object'
  ) THEN
    ALTER TABLE public.subscription_plans
      ADD CONSTRAINT subscription_plans_description_json_is_object
      CHECK (description_json IS NULL OR jsonb_typeof(description_json) = 'object');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'subscription_plans_price_monthly_nonneg'
  ) THEN
    ALTER TABLE public.subscription_plans
      ADD CONSTRAINT subscription_plans_price_monthly_nonneg
      CHECK (price_monthly_cents IS NULL OR price_monthly_cents >= 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'subscription_plans_price_annual_nonneg'
  ) THEN
    ALTER TABLE public.subscription_plans
      ADD CONSTRAINT subscription_plans_price_annual_nonneg
      CHECK (price_annual_cents IS NULL OR price_annual_cents >= 0);
  END IF;
END $$;

-- 3) Backfill structured landing description from legacy description text
UPDATE public.subscription_plans
SET description_json = jsonb_build_object(
  'main', coalesce(description, ''),
  'included', '[]'::jsonb,
  'value', '',
  'result', ''
)
WHERE description_json IS NULL;

-- 4) Normalize JSON shape keys for already-populated rows
UPDATE public.subscription_plans
SET description_json =
  jsonb_set(
    jsonb_set(
      jsonb_set(
        jsonb_set(coalesce(description_json, '{}'::jsonb), '{main}', to_jsonb(coalesce(description_json->>'main', coalesce(description, ''))), true),
        '{included}', coalesce(description_json->'included', '[]'::jsonb), true
      ),
      '{value}', to_jsonb(coalesce(description_json->>'value', '')), true
    ),
    '{result}', to_jsonb(coalesce(description_json->>'result', '')), true
  )
WHERE description_json IS NOT NULL;

-- 5) Backfill monthly/annual summary prices from existing legacy values only
UPDATE public.subscription_plans
SET
  price_monthly_cents = coalesce(
    price_monthly_cents,
    CASE WHEN billing_period = 'month' THEN price_cents END
  ),
  price_annual_cents = coalesce(
    price_annual_cents,
    CASE WHEN billing_period = 'year' THEN price_cents END
  );

-- 6) Trigger: keep backward compatibility + search_tsv fresh
CREATE OR REPLACE FUNCTION public.trg_subscription_plans_marketing_sync()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  json_main text;
  json_value text;
  json_result text;
  json_included text;
  txt text;
BEGIN
  NEW.description_json := coalesce(NEW.description_json, '{}'::jsonb);

  NEW.description_json :=
    jsonb_set(
      jsonb_set(
        jsonb_set(
          jsonb_set(NEW.description_json, '{main}', to_jsonb(coalesce(NEW.description_json->>'main', coalesce(NEW.description, ''))), true),
          '{included}', coalesce(NEW.description_json->'included', '[]'::jsonb), true
        ),
        '{value}', to_jsonb(coalesce(NEW.description_json->>'value', '')), true
      ),
      '{result}', to_jsonb(coalesce(NEW.description_json->>'result', '')), true
    );

  json_main := coalesce(NEW.description_json->>'main', '');
  json_value := coalesce(NEW.description_json->>'value', '');
  json_result := coalesce(NEW.description_json->>'result', '');
  json_included := coalesce((
    SELECT string_agg(value, ' ')
    FROM jsonb_array_elements_text(coalesce(NEW.description_json->'included', '[]'::jsonb)) AS value
  ), '');

  -- Backward compatibility for existing API/UI that still read text description
  IF json_main <> '' THEN
    NEW.description := json_main;
  END IF;

  txt := concat_ws(' ',
    coalesce(NEW.code, ''),
    coalesce(NEW.name, ''),
    coalesce(NEW.description, ''),
    json_main,
    json_included,
    json_value,
    json_result
  );

  NEW.search_tsv := public.es_en_tsv(txt);
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'subscription_plans'
      AND t.tgname = 'trg_subscription_plans_marketing_sync'
  ) THEN
    DROP TRIGGER trg_subscription_plans_marketing_sync ON public.subscription_plans;
  END IF;

  CREATE TRIGGER trg_subscription_plans_marketing_sync
  BEFORE INSERT OR UPDATE OF code, name, description, description_json
  ON public.subscription_plans
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_subscription_plans_marketing_sync();
END $$;

-- 7) Rebuild search_tsv for existing rows with normalized data
UPDATE public.subscription_plans sp
SET
  updated_at = now(),
  description = coalesce(sp.description_json->>'main', sp.description),
  search_tsv = public.es_en_tsv(
    concat_ws(' ',
      coalesce(sp.code, ''),
      coalesce(sp.name, ''),
      coalesce(sp.description_json->>'main', coalesce(sp.description, '')),
      coalesce((
        SELECT string_agg(value, ' ')
        FROM jsonb_array_elements_text(coalesce(sp.description_json->'included', '[]'::jsonb)) AS value
      ), ''),
      coalesce(sp.description_json->>'value', ''),
      coalesce(sp.description_json->>'result', '')
    )
  );
