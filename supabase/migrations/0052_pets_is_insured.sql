-- ============================================================
-- 0052: Add is_insured column to pets table
-- ============================================================
-- Adds boolean insurance status field to horses, collected during
-- the horse KYC onboarding flow.

BEGIN;

ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS is_insured boolean;

COMMIT;
