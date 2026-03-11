-- 0036_subscription_plans_marketing_structure.sql
-- Make subscription_plans compatible with landing-page structured content while preserving legacy fields.

ALTER TABLE public.subscription_plans
  ADD COLUMN IF NOT EXISTS description_json jsonb,
  ADD COLUMN IF NOT EXISTS price_monthly_cents integer,
  ADD COLUMN IF NOT EXISTS price_annual_cents integer;

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

-- Backfill structured description from legacy text.
UPDATE public.subscription_plans
SET description_json = jsonb_build_object(
  'main', coalesce(description, ''),
  'included', '[]'::jsonb,
  'value', '',
  'result', ''
)
WHERE description_json IS NULL;

-- Backfill summary monthly/annual prices from normalized price table when available.
WITH price_rollup AS (
  SELECT
    spp.plan_id,
    max(CASE WHEN spp.billing_period = 'month' AND spp.is_active THEN stripe_pricing.unit_amount END) AS month_amount,
    max(CASE WHEN spp.billing_period = 'year'  AND spp.is_active THEN stripe_pricing.unit_amount END) AS year_amount
  FROM public.subscription_plan_prices spp
  LEFT JOIN stripe.prices stripe_pricing ON stripe_pricing.id = spp.stripe_price_id
  GROUP BY spp.plan_id
)
UPDATE public.subscription_plans sp
SET
  price_monthly_cents = coalesce(sp.price_monthly_cents, price_rollup.month_amount),
  price_annual_cents = coalesce(sp.price_annual_cents, price_rollup.year_amount)
FROM price_rollup
WHERE sp.id = price_rollup.plan_id;

-- Fallback from legacy price fields.
UPDATE public.subscription_plans
SET
  price_monthly_cents = coalesce(price_monthly_cents, CASE WHEN billing_period = 'month' THEN price_cents END),
  price_annual_cents = coalesce(price_annual_cents, CASE WHEN billing_period = 'year' THEN price_cents END);

CREATE OR REPLACE FUNCTION public.trg_subscription_plans_marketing_sync()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  txt text;
  json_main text;
  json_value text;
  json_result text;
  json_included text;
BEGIN
  json_main := coalesce(NEW.description_json->>'main', '');
  json_value := coalesce(NEW.description_json->>'value', '');
  json_result := coalesce(NEW.description_json->>'result', '');
  json_included := coalesce((
    SELECT string_agg(value, ' ')
    FROM jsonb_array_elements_text(coalesce(NEW.description_json->'included', '[]'::jsonb)) AS value
  ), '');

  -- Backward compatibility: keep legacy text description populated from structured main copy.
  IF (NEW.description IS NULL OR btrim(NEW.description) = '') AND json_main <> '' THEN
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
  BEGIN
    CREATE TRIGGER trg_subscription_plans_marketing_sync
    BEFORE INSERT OR UPDATE OF code, name, description, description_json
    ON public.subscription_plans
    FOR EACH ROW
    EXECUTE FUNCTION public.trg_subscription_plans_marketing_sync();
  EXCEPTION WHEN duplicate_object THEN
    NULL;
  END;
END $$;

-- Recompute search vector for existing rows with full text sources.
UPDATE public.subscription_plans sp
SET
  updated_at = now(),
  search_tsv = public.es_en_tsv(
    concat_ws(' ',
      coalesce(sp.code, ''),
      coalesce(sp.name, ''),
      coalesce(sp.description, ''),
      coalesce(sp.description_json->>'main', ''),
      coalesce((
        SELECT string_agg(value, ' ')
        FROM jsonb_array_elements_text(coalesce(sp.description_json->'included', '[]'::jsonb)) AS value
      ), ''),
      coalesce(sp.description_json->>'value', ''),
      coalesce(sp.description_json->>'result', '')
    )
  );
