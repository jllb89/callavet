-- Prevent double consumption linkage for the same overage_purchase
-- Adds a unique index on entitlement_consumptions.overage_purchase_id where not null
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'uniq_consumptions_overage_purchase'
  ) THEN
    CREATE UNIQUE INDEX uniq_consumptions_overage_purchase
      ON public.entitlement_consumptions (overage_purchase_id)
      WHERE overage_purchase_id IS NOT NULL;
  END IF;
END $$;
