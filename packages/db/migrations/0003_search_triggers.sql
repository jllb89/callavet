-- Maintain search_tsv via triggers (Spanish + English)
-- Idempotent: CREATE OR REPLACE FUNCTION and CREATE TRIGGER IF NOT EXISTS guarded by naming convention

-- Generic trigger function that updates NEW.search_tsv based on table name
CREATE OR REPLACE FUNCTION trg_update_search_tsv()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  txt text := '';
BEGIN
  -- Build concatenated text per table
  IF TG_TABLE_NAME = 'users' THEN
    txt := coalesce(NEW.email,'') || ' ' || coalesce(NEW.full_name,'') || ' ' || coalesce(NEW.phone,'');
  ELSIF TG_TABLE_NAME = 'pets' THEN
    txt := coalesce(NEW.name,'') || ' ' || coalesce(NEW.species,'') || ' ' || coalesce(NEW.breed,'') || ' ' || coalesce(NEW.medical_notes,'');
  ELSIF TG_TABLE_NAME = 'vets' THEN
    txt := coalesce(NEW.bio,'') || ' ' || array_to_string(NEW.languages, ' ') || ' ' || array_to_string(NEW.specialties::text[], ' ');
  ELSIF TG_TABLE_NAME = 'products' THEN
    txt := coalesce(NEW.name,'') || ' ' || coalesce(NEW.description,'') || ' ' || array_to_string(NEW.tags, ' ');
  ELSIF TG_TABLE_NAME = 'services' THEN
    txt := coalesce(NEW.name,'') || ' ' || coalesce(NEW.description,'') || ' ' || array_to_string(NEW.tags, ' ');
  ELSIF TG_TABLE_NAME = 'service_providers' THEN
    txt := coalesce(NEW.name,'') || ' ' || coalesce(NEW.description,'') || ' ' || coalesce(NEW.type,'');
  ELSIF TG_TABLE_NAME = 'vet_care_centers' THEN
    txt := coalesce(NEW.name,'') || ' ' || coalesce(NEW.description,'') || ' ' || coalesce(NEW.address,'');
  ELSIF TG_TABLE_NAME = 'chat_sessions' THEN
    txt := coalesce(NEW.status,'');
  ELSIF TG_TABLE_NAME = 'messages' THEN
    txt := coalesce(NEW.content,'');
  ELSIF TG_TABLE_NAME = 'consultation_notes' THEN
    txt := coalesce(NEW.summary_text,'') || ' ' || coalesce(NEW.plan_summary,'');
  ELSIF TG_TABLE_NAME = 'care_plans' THEN
    txt := coalesce(NEW.short_term,'') || ' ' || coalesce(NEW.mid_term,'') || ' ' || coalesce(NEW.long_term,'');
  ELSIF TG_TABLE_NAME = 'global_pet_health_data' THEN
    txt := array_to_string(NEW.symptoms, ' ') || ' ' || coalesce(NEW.diagnosis_label,'') || ' ' || coalesce(NEW.notes,'');
  ELSIF TG_TABLE_NAME = 'kb_items' THEN
    txt := coalesce(NEW.title,'') || ' ' || coalesce(NEW.body,'') || ' ' || array_to_string(NEW.tags, ' ');
  ELSIF TG_TABLE_NAME = 'appointments' THEN
    txt := coalesce(NEW.status,'');
  ELSIF TG_TABLE_NAME = 'payments' THEN
    txt := coalesce(NEW.status,'');
  ELSIF TG_TABLE_NAME = 'invoices' THEN
    txt := coalesce(NEW.status,'') || ' ' || coalesce(NEW.cfdi_uuid,'');
  ELSIF TG_TABLE_NAME = 'care_plan_items' THEN
    txt := coalesce(NEW.type,'') || ' ' || coalesce(NEW.description,'');
  ELSIF TG_TABLE_NAME = 'ratings' THEN
    txt := coalesce(NEW.comment,'');
  ELSIF TG_TABLE_NAME = 'image_cases' THEN
    txt := coalesce(NEW.diagnosis_label,'') || ' ' || coalesce(NEW.findings,'') || ' ' || array_to_string(NEW.labels, ' ');
  END IF;

  NEW.search_tsv := es_en_tsv(txt);
  RETURN NEW;
END;
$$;

-- Helper to create trigger if not exists
DO $$
DECLARE
  rec record;
BEGIN
  FOR rec IN SELECT tgname FROM pg_trigger WHERE tgname IN (
    'trg_users_search_tsv',
    'trg_pets_search_tsv',
    'trg_vets_search_tsv',
    'trg_products_search_tsv',
    'trg_services_search_tsv',
    'trg_service_providers_search_tsv',
    'trg_vet_care_centers_search_tsv',
    'trg_chat_sessions_search_tsv',
    'trg_messages_search_tsv',
    'trg_consultation_notes_search_tsv',
    'trg_care_plans_search_tsv',
    'trg_global_pet_health_data_search_tsv',
    'trg_kb_items_search_tsv',
    'trg_appointments_search_tsv',
    'trg_payments_search_tsv',
    'trg_invoices_search_tsv',
    'trg_care_plan_items_search_tsv',
    'trg_ratings_search_tsv',
    'trg_image_cases_search_tsv'
  ) LOOP
    -- No-op to allow idempotency
  END LOOP;
END$$;

-- Create triggers (IF NOT EXISTS workaround via catch)
DO $$
BEGIN
  BEGIN
    CREATE TRIGGER trg_users_search_tsv BEFORE INSERT OR UPDATE OF email, full_name, phone ON users
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_pets_search_tsv BEFORE INSERT OR UPDATE OF name, species, breed, medical_notes ON pets
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_vets_search_tsv BEFORE INSERT OR UPDATE OF bio, languages, specialties ON vets
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_products_search_tsv BEFORE INSERT OR UPDATE OF name, description, tags ON products
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_services_search_tsv BEFORE INSERT OR UPDATE OF name, description, tags ON services
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_service_providers_search_tsv BEFORE INSERT OR UPDATE OF name, description, type ON service_providers
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_vet_care_centers_search_tsv BEFORE INSERT OR UPDATE OF name, description, address ON vet_care_centers
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_chat_sessions_search_tsv BEFORE INSERT OR UPDATE OF status ON chat_sessions
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_messages_search_tsv BEFORE INSERT OR UPDATE OF content ON messages
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_consultation_notes_search_tsv BEFORE INSERT OR UPDATE OF summary_text, plan_summary ON consultation_notes
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_care_plans_search_tsv BEFORE INSERT OR UPDATE OF short_term, mid_term, long_term ON care_plans
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_global_pet_health_data_search_tsv BEFORE INSERT OR UPDATE OF symptoms, diagnosis_label, notes ON global_pet_health_data
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_kb_items_search_tsv BEFORE INSERT OR UPDATE OF title, body, tags ON kb_items
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_appointments_search_tsv BEFORE INSERT OR UPDATE OF status ON appointments
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_payments_search_tsv BEFORE INSERT OR UPDATE OF status ON payments
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_invoices_search_tsv BEFORE INSERT OR UPDATE OF status, cfdi_uuid ON invoices
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_care_plan_items_search_tsv BEFORE INSERT OR UPDATE OF type, description ON care_plan_items
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_ratings_search_tsv BEFORE INSERT OR UPDATE OF comment ON ratings
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;

  BEGIN
    CREATE TRIGGER trg_image_cases_search_tsv BEFORE INSERT OR UPDATE OF labels, findings, diagnosis_label ON image_cases
    FOR EACH ROW EXECUTE FUNCTION trg_update_search_tsv();
  EXCEPTION WHEN duplicate_object THEN END;
END$$;
