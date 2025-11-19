-- 0009_horse_cleanup.sql
-- Purpose: Enforce horse-only Phase 1 dataset by removing legacy dog content
-- and inserting minimal equine KB articles if none exist. Safe to run multiple times.
-- NOTE: Executed as postgres (migration user) so RLS is bypassed.

BEGIN;

-- Remove dog KB articles (species array contains 'dog')
DELETE FROM kb_articles WHERE species && ARRAY['dog']::text[];

-- Remove dog pets (simple species column heuristics)
DELETE FROM pets WHERE LOWER(species) = 'dog' OR LOWER(species) LIKE '%dog%';

-- Optional: Remove dog-specific vet care centers if any (name heuristic)
DELETE FROM vet_care_centers WHERE LOWER(name) LIKE '%dog%';

-- Seed horse KB articles if none tagged 'horse'
DO $$
DECLARE
  has_horse boolean;
BEGIN
  SELECT EXISTS(SELECT 1 FROM kb_articles WHERE species && ARRAY['horse']::text[]) INTO has_horse;
  IF NOT has_horse THEN
    INSERT INTO kb_articles (title, content, species, tags, language, author_user_id)
    VALUES
      ('Colic Early Signs in Horses',
       'Restlessness, pawing, flank watching, reduced manure. Early vet intervention reduces risk of surgical colic.',
       ARRAY['horse'], ARRAY['colic','emergency'], 'en', '00000000-0000-0000-0000-000000000002'),
      ('Basic Hoof Care',
       'Daily hoof picking removes trapped stones and manure. Schedule farrier visits every 6-8 weeks to prevent imbalances.',
       ARRAY['horse'], ARRAY['hoof','care'], 'en', '00000000-0000-0000-0000-000000000002');
  END IF;
END$$;

COMMIT;
