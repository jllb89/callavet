-- Add INSERT/UPDATE policies for consultation_notes and care_plans
-- Enables vets to create notes and owners/admin to manage care plans

-- Consultation notes: allow INSERT by current vet (auth.uid()) and admins
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = current_schema() AND tablename = 'consultation_notes' AND policyname = 'consultation_notes_insert_vet'
  ) THEN
    CREATE POLICY consultation_notes_insert_vet ON consultation_notes
      FOR INSERT
      WITH CHECK (
        vet_id = auth.uid() OR is_admin()
      );
  END IF;
END$$;

-- Consultation notes: allow INSERT by pet owner as well
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = current_schema() AND tablename = 'consultation_notes' AND policyname = 'consultation_notes_insert_owner'
  ) THEN
    CREATE POLICY consultation_notes_insert_owner ON consultation_notes
      FOR INSERT
      WITH CHECK (
        EXISTS (SELECT 1 FROM pets p WHERE p.id = consultation_notes.pet_id AND p.user_id = auth.uid())
        OR is_admin()
      );
  END IF;
END$$;

-- Care plans: allow INSERT by owner (user linked via pet) or admin
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = current_schema() AND tablename = 'care_plans' AND policyname = 'care_plans_insert_owner'
  ) THEN
    CREATE POLICY care_plans_insert_owner ON care_plans
      FOR INSERT
      WITH CHECK (
        EXISTS (SELECT 1 FROM pets p WHERE p.id = care_plans.pet_id AND p.user_id = auth.uid())
        OR is_admin()
      );
  END IF;
END$$;

-- Care plan items: allow UPDATE (patch) when owner of pet behind the plan or admin
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = current_schema() AND tablename = 'care_plan_items' AND policyname = 'care_plan_items_update_owner'
  ) THEN
    CREATE POLICY care_plan_items_update_owner ON care_plan_items
      FOR UPDATE
      USING (
        EXISTS (
          SELECT 1 FROM care_plans cp
          JOIN pets p ON p.id = cp.pet_id
          WHERE cp.id = care_plan_items.care_plan_id AND p.user_id = auth.uid()
        )
        OR is_admin()
      );
  END IF;
END$$;
