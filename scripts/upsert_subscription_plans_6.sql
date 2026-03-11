WITH plan_data AS (
  SELECT
    code,
    name,
    monthly_cents,
    annual_cents,
    main_desc,
    included_items,
    value_desc,
    result_desc,
    included_chats,
    included_videos,
    pets_included
  FROM (
    VALUES
      (
        'starter',
        'Starter',
        99900,
        89900,
        'Ideal para dueños individuales que quieren orientación rápida sin pagar visitas innecesarias.',
        ARRAY[
          '2 chats veterinarios al mes.',
          'Pre-diagnóstico y direccionamiento con especialistas por medio de IA.',
          'Historial clínico digital del caballo.',
          'Planes de cuidado propuestos (gratis).'
        ]::text[],
        'Una sola consulta digital puede evitar una visita física innecesaria que cuesta más que todo el plan.',
        'Tranquilidad, respuesta inmediata y ahorro desde el primer mes.',
        2,
        0,
        1
      ),
      (
        'plus',
        'Plus',
        189900,
        169900,
        'Ideal para dueños individuales que quieren orientación rápida sin pagar visitas innecesarias.',
        ARRAY[
          '1 videollamada veterinaria al mes.',
          '3 chats veterinarios al mes.',
          'Pre-diagnóstico y direccionamiento con especialistas por medio de IA.',
          'Historial clínico digital del caballo.',
          'Planes de cuidado propuestos personalizados con recordatorios de vacunas, desparacitación y coggins.',
          'Prioridad de atención media.'
        ]::text[],
        'Combina prevención + seguimiento continuo por menos de lo que cuesta una sola urgencia tradicional.',
        'Menos improvisación, mejores decisiones y control total de la salud del caballo.',
        3,
        1,
        1
      ),
      (
        'cuadra',
        'Cuadra 5',
        249900,
        229900,
        'Ideal para dueños individuales que quieren orientación rápida sin pagar visitas innecesarias.',
        ARRAY[
          'Gestión de hasta 5 caballos en un solo plan.',
          '6 chats veterinarios compartidos.',
          '2 videollamadas veterinarias al mes.',
          'Pre-diagnóstico y direccionamiento con especialistas por medio de IA.',
          'Historial clínico individual por caballo.',
          'Planes de cuidado propuestos por IA.',
          'Atención prioritaria.'
        ]::text[],
        'Reduce visitas físicas, optimiza tiempos y centraliza toda la información médica de la cuadra.',
        'Ahorros mensuales reales frente a atención tradicional fragmentada.',
        6,
        2,
        5
      ),
      (
        'cuadra-15',
        'Cuadra 15',
        349900,
        309900,
        'Ideal para dueños individuales que quieren orientación rápida sin pagar visitas innecesarias.',
        ARRAY[
          'Hasta 15 caballos bajo un mismo plan.',
          '20 chats veterinarios mensuales.',
          '6 videollamadas veterinarias.',
          'Historial clínico avanzado por caballo.',
          'Planes de cuidado propuestos y seguimiento.',
          'Prioridad alta en atención.'
        ]::text[],
        'Ahorros operativos significativos al reducir urgencias presenciales y tiempos muertos.',
        'Salud equina gestionada como sistema, no como emergencias aisladas.',
        20,
        6,
        15
      ),
      (
        'pro-entrenador',
        'Pro Entrenador',
        249900,
        229900,
        'Ideal para dueños individuales que quieren orientación rápida sin pagar visitas innecesarias.',
        ARRAY[
          '10 chats veterinarios al mes.',
          '3 videollamadas al mes.',
          'Pre-diagnóstico con IA para cada caso.',
          'Seguimiento clínico continuo.',
          'Historial estructurado por caballo.',
          'Acceso preferente a veterinarios.'
        ]::text[],
        'Permite resolver múltiples situaciones al mes sin depender de visitas presenciales constantes.',
        'Más control, menos interrupciones operativas y mejor desempeño del equipo.',
        10,
        3,
        5
      ),
      (
        'rancho-trabajo',
        'Rancho de Trabajo',
        499900,
        449900,
        'Ideal para ranchos, centros de trabajo y operaciones intensivas.',
        ARRAY[
          'Gestión de hasta 25 caballos.',
          '25 chats veterinarios mensuales.',
          '5 videollamadas incluidas.',
          'Historial clínico completo y centralizado.',
          'Planes de cuidado preventivos.',
          'Atención prioritaria máxima.'
        ]::text[],
        'Optimiza costos veterinarios, mejora la prevención y profesionaliza la toma de decisiones.',
        'Menos urgencias, mejor planificación y control total de la operación.',
        25,
        5,
        25
      )
  ) AS v(
    code,
    name,
    monthly_cents,
    annual_cents,
    main_desc,
    included_items,
    value_desc,
    result_desc,
    included_chats,
    included_videos,
    pets_included
  )
)
INSERT INTO public.subscription_plans (
  id,
  code,
  name,
  description,
  description_json,
  price_cents,
  price_monthly_cents,
  price_annual_cents,
  currency,
  billing_period,
  included_chats,
  included_videos,
  pets_included_default,
  tax_rate,
  is_active,
  updated_at
)
SELECT
  gen_random_uuid(),
  pd.code,
  pd.name,
  pd.main_desc,
  jsonb_build_object(
    'main', pd.main_desc,
    'included', to_jsonb(pd.included_items),
    'value', pd.value_desc,
    'result', pd.result_desc
  ),
  pd.monthly_cents,
  pd.monthly_cents,
  pd.annual_cents,
  'MXN',
  'month',
  pd.included_chats,
  pd.included_videos,
  pd.pets_included,
  0.16,
  true,
  now()
FROM plan_data pd
ON CONFLICT (code) DO UPDATE
SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  description_json = EXCLUDED.description_json,
  price_cents = EXCLUDED.price_cents,
  price_monthly_cents = EXCLUDED.price_monthly_cents,
  price_annual_cents = EXCLUDED.price_annual_cents,
  currency = EXCLUDED.currency,
  billing_period = EXCLUDED.billing_period,
  included_chats = EXCLUDED.included_chats,
  included_videos = EXCLUDED.included_videos,
  pets_included_default = EXCLUDED.pets_included_default,
  tax_rate = EXCLUDED.tax_rate,
  is_active = EXCLUDED.is_active,
  updated_at = now();

SELECT
  code,
  name,
  price_monthly_cents,
  price_annual_cents,
  included_chats,
  included_videos,
  pets_included_default
FROM public.subscription_plans
ORDER BY code;
