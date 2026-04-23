-- ============================================================
-- 0043: Horse KYC Schema Expansion for Phase 4
-- ============================================================
-- Restructures pets table to store comprehensive horse health,
-- activity, and management data as individual columns instead of JSON.
-- This enables server-side querying, vector embedding, vet assignment,
-- and AI care plan generation based on structured horse attributes.

BEGIN;

-- Add new KYC columns to pets table
ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS sex text
  CHECK (sex IN ('male', 'female', 'gelding'));

ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS age_range text
  CHECK (age_range IN ('foal_0_2', 'young_3_5', 'adult_6_15', 'senior_16_plus'));

ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS weight_range text
  CHECK (weight_range IN ('lt_400', '400_500', '500_600', 'gt_600'));

-- Location fields (from nested object in JSON schema)
ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS location_country text;
ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS location_state_region text;

-- Breed and breed conditionals
ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS breed text
  CHECK (breed IN (
    'quarter_horse', 'thoroughbred', 'pre', 'arabian', 'criollo',
    'appaloosa', 'paint_horse', 'warmblood', 'mixed', 'other'
  ));

ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS warmblood_subbreed text
  CHECK (warmblood_subbreed IS NULL OR warmblood_subbreed IN (
    'holsteiner', 'hanoverian', 'kwpn', 'oldenburg', 'selle_francais',
    'westphalian', 'trakehner', 'other'
  ));

ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS other_breed_text text
  CHECK (other_breed_text IS NULL OR length(other_breed_text) <= 100);

-- Activity and discipline
ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS primary_activity text
  CHECK (primary_activity IN (
    'competition', 'regular_training', 'rehabilitation_recovery', 'retired', 'recreational'
  ));

ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS discipline text
  CHECK (discipline IN (
    'jumping', 'dressage', 'polo', 'endurance', 'barrel_racing',
    'reining', 'charreada', 'ranch_work', 'recreational', 'other'
  ));

ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS other_discipline_text text
  CHECK (other_discipline_text IS NULL OR length(other_discipline_text) <= 100);

-- Training and environment
ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS training_intensity text
  CHECK (training_intensity IN ('1_2_per_week', '3_4_per_week', '5_plus_per_week'));

ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS terrain text
  CHECK (terrain IN ('sand', 'grass', 'dirt', 'mixed', 'other'));

ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS other_terrain_text text
  CHECK (other_terrain_text IS NULL OR length(other_terrain_text) <= 100);

-- Health observations and conditions (arrays of enums)
ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS observed_last_6_months text[] DEFAULT '{}'::text[];
ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS known_conditions text[] DEFAULT '{}'::text[];

-- Health management
ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS current_treatments_or_supplements text
  CHECK (current_treatments_or_supplements IS NULL OR length(current_treatments_or_supplements) <= 500);

ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS last_vet_check text
  CHECK (last_vet_check IN ('lt_3_months', '3_6_months', 'gt_6_months', 'dont_remember'));

ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS vaccines_up_to_date text
  CHECK (vaccines_up_to_date IN ('yes', 'no', 'not_sure'));

ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS deworming_status text
  CHECK (deworming_status IN ('regular', 'irregular', 'not_sure'));

ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS additional_notes text
  CHECK (additional_notes IS NULL OR length(additional_notes) <= 1000);

-- Replace legacy generated search_tsv/triggers that depend on medical_notes.
DROP TRIGGER IF EXISTS trg_pets_search_tsv ON public.pets;
ALTER TABLE public.pets DROP COLUMN IF EXISTS search_tsv;
ALTER TABLE public.pets ADD COLUMN IF NOT EXISTS search_tsv tsvector;
CREATE INDEX IF NOT EXISTS pets_tsv_gin ON public.pets USING GIN (search_tsv);

-- Drop old unstructured columns
ALTER TABLE public.pets DROP COLUMN IF EXISTS birthdate;
ALTER TABLE public.pets DROP COLUMN IF EXISTS weight_kg;
ALTER TABLE public.pets DROP COLUMN IF EXISTS medical_notes;

-- Add check constraints for conditional dependencies

-- If breed='warmblood', then warmblood_subbreed must be set
ALTER TABLE public.pets ADD CONSTRAINT breed_warmblood_requires_subbreed
  CHECK (breed != 'warmblood' OR warmblood_subbreed IS NOT NULL);

-- If breed='other', then other_breed_text must be set
ALTER TABLE public.pets ADD CONSTRAINT breed_other_requires_text
  CHECK (breed != 'other' OR other_breed_text IS NOT NULL);

-- If discipline='other', then other_discipline_text must be set
ALTER TABLE public.pets ADD CONSTRAINT discipline_other_requires_text
  CHECK (discipline != 'other' OR other_discipline_text IS NOT NULL);

-- If terrain='other', then other_terrain_text must be set
ALTER TABLE public.pets ADD CONSTRAINT terrain_other_requires_text
  CHECK (terrain != 'other' OR other_terrain_text IS NOT NULL);

-- If observed_last_6_months contains 'none', it must be the only value
ALTER TABLE public.pets ADD CONSTRAINT observed_6m_none_exclusive
  CHECK (
    NOT (array_length(observed_last_6_months, 1) > 1 AND 'none' = ANY(observed_last_6_months))
  );

-- If known_conditions contains 'none', it must be the only value
ALTER TABLE public.pets ADD CONSTRAINT known_conditions_none_exclusive
  CHECK (
    NOT (array_length(known_conditions, 1) > 1 AND 'none' = ANY(known_conditions))
  );

-- Add validation constraint for enum arrays
ALTER TABLE public.pets ADD CONSTRAINT observed_6m_valid_values
  CHECK (
    observed_last_6_months <@ ARRAY['mild_lameness', 'stiffness', 'performance_drop', 'appetite_changes', 'none']::text[]
  );

ALTER TABLE public.pets ADD CONSTRAINT known_conditions_valid_values
  CHECK (
    known_conditions <@ ARRAY['digestive', 'locomotor', 'respiratory', 'skin', 'none']::text[]
  );

-- Rebuild search vector to include new fields
CREATE OR REPLACE FUNCTION rebuild_pet_search_vector()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.search_tsv := public.es_en_tsv(
    coalesce(NEW.name, '') || ' ' ||
    coalesce(NEW.breed, '') || ' ' ||
    coalesce(NEW.primary_activity, '') || ' ' ||
    coalesce(NEW.discipline, '') || ' ' ||
    coalesce(NEW.location_country, '') || ' ' ||
    coalesce(NEW.location_state_region, '')
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS rebuild_pet_search_vector_trigger ON public.pets;
CREATE TRIGGER rebuild_pet_search_vector_trigger
BEFORE INSERT OR UPDATE ON public.pets
FOR EACH ROW
EXECUTE FUNCTION rebuild_pet_search_vector();

-- Regenerate search vectors for existing pets
UPDATE public.pets SET search_tsv = public.es_en_tsv(
  coalesce(name, '') || ' ' ||
  coalesce(breed, '') || ' ' ||
  coalesce(primary_activity, '') || ' ' ||
  coalesce(discipline, '') || ' ' ||
  coalesce(location_country, '') || ' ' ||
  coalesce(location_state_region, '')
);

-- Create GIN index on array columns for efficient queries
CREATE INDEX IF NOT EXISTS pets_observed_6m_gin ON public.pets USING GIN (observed_last_6_months);
CREATE INDEX IF NOT EXISTS pets_known_conditions_gin ON public.pets USING GIN (known_conditions);

-- Create indexes on frequently queried KYC fields
CREATE INDEX IF NOT EXISTS pets_breed_idx ON public.pets (breed);
CREATE INDEX IF NOT EXISTS pets_primary_activity_idx ON public.pets (primary_activity);
CREATE INDEX IF NOT EXISTS pets_discipline_idx ON public.pets (discipline);
CREATE INDEX IF NOT EXISTS pets_location_idx ON public.pets (location_country, location_state_region);

COMMIT;
