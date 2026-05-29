-- 0053_vet_specialty_hygiene.sql
-- Deduplicate legacy randomized specialty seeds and install an active Spanish equine catalog.

DO $$
BEGIN
  IF to_regclass('public.vet_specialties') IS NULL THEN
    RAISE NOTICE 'vet_specialties missing; skipping specialty hygiene';
    RETURN;
  END IF;

  DROP INDEX IF EXISTS vet_specialties_name_norm_unique;

  ALTER TABLE vet_specialties ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;
  ALTER TABLE vet_specialties ADD COLUMN IF NOT EXISTS sort_order integer NOT NULL DEFAULT 100;

  UPDATE vet_specialties
    SET name = 'Medicina general equina',
      description = 'Atención primaria, triaje, prevención, vacunas, chequeos, síntomas vagos, cambios de apetito y consultas generales para caballos',
      sort_order = 10
  WHERE id = '10000000-0000-0000-0000-000000000001'::uuid
    OR lower(btrim(name)) IN ('equine gp', 'general equine medicine', 'equine general practice', 'medicina general', 'medicina general equina');

  UPDATE vet_specialties
    SET name = 'Medicina interna equina',
      description = 'Enfermedad sistémica, fiebre, pérdida de peso, signos respiratorios, problemas metabólicos o endocrinos y casos médicos complejos',
      sort_order = 20
  WHERE id = '10000000-0000-0000-0000-000000000002'::uuid
    OR lower(btrim(name)) IN ('equine internal medicine', 'medicina interna', 'medicina interna equina');

  UPDATE vet_specialties
    SET name = 'Urgencias equinas y cuidados críticos',
      description = 'Urgencias, cólico con señales de alarma, dolor severo, sangrado, dificultad respiratoria, incapacidad para levantarse y estabilización',
      sort_order = 30
  WHERE id = '10000000-0000-0000-0000-000000000003'::uuid
    OR lower(btrim(name)) IN ('equine emergency and critical care', 'emergency', 'urgencias equinas', 'urgencias equinas y cuidados críticos');

  UPDATE vet_specialties
    SET name = 'Gastroenterología equina',
      description = 'No quiere comer, cambios de apetito, cólico, diarrea, cambios en heces, úlceras y molestias gastrointestinales',
      sort_order = 40
  WHERE id = '10000000-0000-0000-0000-000000000004'::uuid
    OR lower(btrim(name)) IN ('equine gastroenterology', 'gastroenterologia equina', 'gastroenterología equina');

  UPDATE vet_specialties
    SET name = 'Ortopedia y cojeras',
      description = 'Cojera, rigidez, cambios de marcha, articulaciones, tendones, ligamentos, cascos y evaluación musculoesquelética',
      sort_order = 50
  WHERE id = '10000000-0000-0000-0000-000000000005'::uuid
    OR lower(btrim(name)) IN ('equine orthopedics and lameness', 'orthopedics', 'lameness', 'ortopedia y cojeras');

  UPDATE vet_specialties
    SET name = 'Cirugía equina',
      description = 'Procedimientos quirúrgicos, heridas, masas, trauma, consulta quirúrgica y cuidado pre/postoperatorio',
      sort_order = 60
  WHERE id = '10000000-0000-0000-0000-000000000006'::uuid
    OR lower(btrim(name)) IN ('surgery', 'equine surgery', 'cirugia equina', 'cirugía equina');

  UPDATE vet_specialties
    SET name = 'Reproducción equina',
      description = 'Yeguas, sementales, gestación, parto, fertilidad, planificación neonatal y medicina reproductiva',
      sort_order = 70
  WHERE id = '10000000-0000-0000-0000-000000000007'::uuid
    OR lower(btrim(name)) IN ('equine reproduction', 'reproduccion equina', 'reproducción equina');

  UPDATE vet_specialties
    SET name = 'Odontología equina',
      description = 'Dientes, dificultad para masticar, dolor de boca, odontología preventiva, limado dental y lesiones orales',
      sort_order = 80
  WHERE id = '10000000-0000-0000-0000-000000000008'::uuid
    OR lower(btrim(name)) IN ('equine dentistry', 'dentistry', 'odontologia equina', 'odontología equina');

  UPDATE vet_specialties
    SET name = 'Dermatología equina',
      description = 'Piel, alergias, comezón, ronchas, heridas superficiales, caída de pelo, pelaje y parásitos externos',
      sort_order = 90
  WHERE id = '10000000-0000-0000-0000-000000000009'::uuid
    OR lower(btrim(name)) IN ('dermatology', 'equine dermatology', 'dermatologia equina', 'dermatología equina');

  UPDATE vet_specialties
    SET name = 'Oftalmología equina',
      description = 'Dolor ocular, lagrimeo, lesiones de córnea, inflamación de párpados, visión y urgencias oculares',
      sort_order = 100
  WHERE id = '10000000-0000-0000-0000-000000000010'::uuid
    OR lower(btrim(name)) IN ('equine ophthalmology', 'ophthalmology', 'oftalmologia equina', 'oftalmología equina');

  UPDATE vet_specialties
    SET name = 'Nutrición equina',
      description = 'Dieta, suplementos, condición corporal, pérdida o ganancia de peso, planes de alimentación y transiciones de alimento',
      sort_order = 110
  WHERE id = '10000000-0000-0000-0000-000000000011'::uuid
    OR lower(btrim(name)) IN ('equine nutrition', 'nutrition', 'nutricion equina', 'nutrición equina');

  UPDATE vet_specialties
    SET name = 'Medicina deportiva y rehabilitación equina',
      description = 'Rendimiento deportivo, acondicionamiento, rehabilitación, recuperación y retorno al trabajo',
      sort_order = 120
  WHERE id = '10000000-0000-0000-0000-000000000012'::uuid
    OR lower(btrim(name)) IN ('equine sports medicine and rehabilitation', 'sports medicine', 'rehabilitation', 'medicina deportiva y rehabilitación equina');

  CREATE TEMP TABLE tmp_vet_specialty_dedupe ON COMMIT DROP AS
  WITH ranked AS (
    SELECT
      id,
      first_value(id) OVER (
        PARTITION BY lower(btrim(name))
        ORDER BY CASE WHEN id::text LIKE '10000000-0000-0000-0000-0000000000%' THEN 0 ELSE 1 END,
                 is_active DESC,
                 length(coalesce(description, '')) DESC,
                 id ASC
      ) AS keep_id
    FROM vet_specialties
    WHERE nullif(btrim(name), '') IS NOT NULL
  )
  SELECT id AS duplicate_id, keep_id
  FROM ranked
  WHERE id <> keep_id;

  IF to_regclass('public.vets') IS NOT NULL THEN
    UPDATE vets v
       SET specialties = mapped.specialties
      FROM (
        SELECT
          v.id,
          coalesce(array_agg(DISTINCT coalesce(d.keep_id, item.specialty_id)) FILTER (WHERE coalesce(d.keep_id, item.specialty_id) IS NOT NULL), '{}'::uuid[]) AS specialties
        FROM vets v
        LEFT JOIN LATERAL unnest(coalesce(v.specialties, '{}'::uuid[])) AS item(specialty_id) ON true
        LEFT JOIN tmp_vet_specialty_dedupe d ON d.duplicate_id = item.specialty_id
        GROUP BY v.id
      ) mapped
     WHERE mapped.id = v.id;
  END IF;

  IF to_regclass('public.vet_referrals') IS NOT NULL THEN
    UPDATE vet_referrals vr
       SET specialty_id = d.keep_id
      FROM tmp_vet_specialty_dedupe d
     WHERE vr.specialty_id = d.duplicate_id;
  END IF;

  DELETE FROM vet_specialties s
   USING tmp_vet_specialty_dedupe d
   WHERE s.id = d.duplicate_id;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS vet_specialties_name_norm_unique
  ON vet_specialties (lower(btrim(name)));

INSERT INTO vet_specialties (id, name, description, is_active, sort_order)
VALUES
  ('10000000-0000-0000-0000-000000000001','Medicina general equina','Atención primaria, triaje, prevención, vacunas, chequeos, síntomas vagos, cambios de apetito y consultas generales para caballos',true,10),
  ('10000000-0000-0000-0000-000000000002','Medicina interna equina','Enfermedad sistémica, fiebre, pérdida de peso, signos respiratorios, problemas metabólicos o endocrinos y casos médicos complejos',true,20),
  ('10000000-0000-0000-0000-000000000003','Urgencias equinas y cuidados críticos','Urgencias, cólico con señales de alarma, dolor severo, sangrado, dificultad respiratoria, incapacidad para levantarse y estabilización',true,30),
  ('10000000-0000-0000-0000-000000000004','Gastroenterología equina','No quiere comer, cambios de apetito, cólico, diarrea, cambios en heces, úlceras y molestias gastrointestinales',true,40),
  ('10000000-0000-0000-0000-000000000005','Ortopedia y cojeras','Cojera, rigidez, cambios de marcha, articulaciones, tendones, ligamentos, cascos y evaluación musculoesquelética',true,50),
  ('10000000-0000-0000-0000-000000000006','Cirugía equina','Procedimientos quirúrgicos, heridas, masas, trauma, consulta quirúrgica y cuidado pre/postoperatorio',true,60),
  ('10000000-0000-0000-0000-000000000007','Reproducción equina','Yeguas, sementales, gestación, parto, fertilidad, planificación neonatal y medicina reproductiva',true,70),
  ('10000000-0000-0000-0000-000000000008','Odontología equina','Dientes, dificultad para masticar, dolor de boca, odontología preventiva, limado dental y lesiones orales',true,80),
  ('10000000-0000-0000-0000-000000000009','Dermatología equina','Piel, alergias, comezón, ronchas, heridas superficiales, caída de pelo, pelaje y parásitos externos',true,90),
  ('10000000-0000-0000-0000-000000000010','Oftalmología equina','Dolor ocular, lagrimeo, lesiones de córnea, inflamación de párpados, visión y urgencias oculares',true,100),
  ('10000000-0000-0000-0000-000000000011','Nutrición equina','Dieta, suplementos, condición corporal, pérdida o ganancia de peso, planes de alimentación y transiciones de alimento',true,110),
  ('10000000-0000-0000-0000-000000000012','Medicina deportiva y rehabilitación equina','Rendimiento deportivo, acondicionamiento, rehabilitación, recuperación y retorno al trabajo',true,120)
ON CONFLICT (lower(btrim(name))) DO UPDATE
SET description = EXCLUDED.description,
    sort_order = EXCLUDED.sort_order,
    is_active = vet_specialties.is_active;