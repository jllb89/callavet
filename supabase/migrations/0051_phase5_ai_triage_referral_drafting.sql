begin;

create table if not exists public.ai_feature_flags (
  key text primary key,
  enabled boolean not null default false,
  description text,
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (key ~ '^[a-z0-9_.:-]+$')
);

create table if not exists public.ai_prompt_versions (
  id uuid primary key default gen_random_uuid(),
  prompt_key text not null,
  version integer not null,
  model text,
  system_prompt text not null,
  user_template text not null,
  output_schema jsonb not null default '{}'::jsonb,
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  unique (prompt_key, version),
  check (prompt_key ~ '^[a-z0-9_.:-]+$'),
  check (version > 0)
);

create unique index if not exists ai_prompt_versions_one_active_idx
  on public.ai_prompt_versions (prompt_key)
  where is_active;

create table if not exists public.ai_events (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid references public.users(id) on delete set null,
  pet_id uuid references public.pets(id) on delete set null,
  encounter_id uuid references public.clinical_encounters(id) on delete set null,
  session_id uuid references public.chat_sessions(id) on delete set null,
  referral_id uuid references public.vet_referrals(id) on delete set null,
  note_id uuid references public.consultation_notes(id) on delete set null,
  care_plan_id uuid references public.care_plans(id) on delete set null,
  event_type text not null,
  feature_key text not null,
  provider text,
  model text,
  prompt_version_id uuid references public.ai_prompt_versions(id) on delete set null,
  status text not null default 'queued' check (status in ('queued', 'running', 'succeeded', 'failed', 'skipped')),
  request_payload jsonb not null default '{}'::jsonb,
  response_payload jsonb not null default '{}'::jsonb,
  error_text text,
  latency_ms integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (event_type ~ '^[a-z0-9_.:-]+$'),
  check (feature_key ~ '^[a-z0-9_.:-]+$')
);

create index if not exists ai_events_actor_idx on public.ai_events (actor_user_id, created_at desc);
create index if not exists ai_events_pet_idx on public.ai_events (pet_id, created_at desc);
create index if not exists ai_events_encounter_idx on public.ai_events (encounter_id, created_at desc);
create index if not exists ai_events_status_idx on public.ai_events (status, created_at desc);
create index if not exists ai_events_feature_idx on public.ai_events (feature_key, created_at desc);

create or replace view public.ai_job_runs
with (security_invoker = true) as
select
  id,
  event_type as job_type,
  feature_key,
  actor_user_id,
  pet_id,
  encounter_id,
  session_id,
  provider,
  model,
  prompt_version_id,
  status,
  request_payload,
  response_payload,
  error_text,
  latency_ms,
  created_at,
  updated_at
from public.ai_events;

create table if not exists public.ai_drafts (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid references public.users(id) on delete set null,
  pet_id uuid references public.pets(id) on delete set null,
  encounter_id uuid references public.clinical_encounters(id) on delete set null,
  session_id uuid references public.chat_sessions(id) on delete set null,
  referral_id uuid references public.vet_referrals(id) on delete set null,
  note_id uuid references public.consultation_notes(id) on delete set null,
  care_plan_id uuid references public.care_plans(id) on delete set null,
  ai_event_id uuid references public.ai_events(id) on delete set null,
  prompt_version_id uuid references public.ai_prompt_versions(id) on delete set null,
  draft_type text not null check (draft_type in ('triage', 'referral', 'note', 'care_plan')),
  status text not null default 'draft' check (status in ('draft', 'reviewed', 'accepted', 'rejected', 'superseded')),
  payload jsonb not null default '{}'::jsonb,
  review_notes text,
  reviewed_by uuid references public.users(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists ai_drafts_actor_idx on public.ai_drafts (actor_user_id, created_at desc);
create index if not exists ai_drafts_pet_idx on public.ai_drafts (pet_id, created_at desc);
create index if not exists ai_drafts_encounter_idx on public.ai_drafts (encounter_id, created_at desc);
create index if not exists ai_drafts_status_idx on public.ai_drafts (status, created_at desc);
create index if not exists ai_drafts_type_idx on public.ai_drafts (draft_type, created_at desc);

insert into public.ai_feature_flags (key, enabled, description, config)
values
  ('ai.triage', true, 'AI triage intake and preliminary assessment drafting', '{}'::jsonb),
  ('ai.referral', true, 'AI referral specialty and priority recommendations', '{}'::jsonb),
  ('ai.note_draft', true, 'AI consultation note drafting for clinician review', '{}'::jsonb),
  ('ai.care_plan_draft', true, 'AI care-plan drafting for clinician review', '{}'::jsonb),
  ('ai.embeddings_generation', true, 'AI embedding generation jobs for retrieval targets', '{}'::jsonb)
on conflict (key) do nothing;

insert into public.ai_prompt_versions (prompt_key, version, model, system_prompt, user_template, output_schema, is_active)
values
  (
    'ai.triage',
    1,
    null,
    'You are a veterinary triage assistant for equine consults. Provide cautious, reviewable support for licensed clinicians. Never make final diagnoses, never recommend emergency delay, and always flag urgent red flags.',
    'Summarize triage from this structured context: {{context}}',
    '{"type":"object","required":["summary","redFlags","recommendedSpecialty","priority","questions","rationale"],"properties":{"summary":{"type":"string"},"redFlags":{"type":"array","items":{"type":"string"}},"recommendedSpecialty":{"type":"string"},"priority":{"type":"string","enum":["routine","urgent"]},"questions":{"type":"array","items":{"type":"string"}},"rationale":{"type":"string"}}}'::jsonb,
    true
  ),
  (
    'ai.referral',
    1,
    null,
    'You recommend the most appropriate veterinary specialty for an equine case. Use only the provided specialty list and return a reviewable recommendation with rationale.',
    'Recommend referral routing from this context: {{context}}',
    '{"type":"object","required":["specialtyName","priority","rationale","confidence"],"properties":{"specialtyName":{"type":"string"},"priority":{"type":"string","enum":["routine","urgent"]},"rationale":{"type":"string"},"confidence":{"type":"number"}}}'::jsonb,
    true
  ),
  (
    'ai.note_draft',
    1,
    null,
    'You draft veterinary consultation notes for clinician review. Output concise structured text and do not publish or finalize clinical decisions.',
    'Draft a structured consultation note from this context: {{context}}',
    '{"type":"object","required":["summaryText","assessmentText","diagnosisText","planSummary","followUpInstructions","severity"],"properties":{"summaryText":{"type":"string"},"assessmentText":{"type":"string"},"diagnosisText":{"type":"string"},"planSummary":{"type":"string"},"followUpInstructions":{"type":"string"},"severity":{"type":"string","enum":["low","medium","high","critical"]}}}'::jsonb,
    true
  ),
  (
    'ai.care_plan_draft',
    1,
    null,
    'You draft equine care plans for clinician review. Provide short, mid, and long-term plan suggestions with conservative clinical language.',
    'Draft a care plan from this context: {{context}}',
    '{"type":"object","required":["shortTerm","midTerm","longTerm","items"],"properties":{"shortTerm":{"type":"string"},"midTerm":{"type":"string"},"longTerm":{"type":"string"},"items":{"type":"array","items":{"type":"object","properties":{"type":{"type":"string"},"description":{"type":"string"}}}}}}'::jsonb,
    true
  )
on conflict (prompt_key, version) do nothing;

alter table public.ai_feature_flags enable row level security;
alter table public.ai_prompt_versions enable row level security;
alter table public.ai_events enable row level security;
alter table public.ai_drafts enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ai_feature_flags' and policyname = 'ai_feature_flags_select') then
    create policy ai_feature_flags_select on public.ai_feature_flags for select using (true);
  end if;

  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ai_prompt_versions' and policyname = 'ai_prompt_versions_select') then
    create policy ai_prompt_versions_select on public.ai_prompt_versions for select using (true);
  end if;

  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ai_events' and policyname = 'ai_events_select_actor') then
    create policy ai_events_select_actor on public.ai_events for select using (
      actor_user_id = auth.uid()
      or is_admin()
      or exists (select 1 from public.pets p where p.id = ai_events.pet_id and p.user_id = auth.uid())
      or exists (select 1 from public.clinical_encounters ce where ce.id = ai_events.encounter_id and (ce.user_id = auth.uid() or ce.vet_id = auth.uid()))
    );
  end if;

  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ai_events' and policyname = 'ai_events_insert_actor') then
    create policy ai_events_insert_actor on public.ai_events for insert with check (actor_user_id = auth.uid() or is_admin());
  end if;

  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ai_events' and policyname = 'ai_events_update_actor') then
    create policy ai_events_update_actor on public.ai_events for update using (actor_user_id = auth.uid() or is_admin()) with check (actor_user_id = auth.uid() or is_admin());
  end if;

  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ai_drafts' and policyname = 'ai_drafts_select_actor') then
    create policy ai_drafts_select_actor on public.ai_drafts for select using (
      actor_user_id = auth.uid()
      or is_admin()
      or exists (select 1 from public.pets p where p.id = ai_drafts.pet_id and p.user_id = auth.uid())
      or exists (select 1 from public.clinical_encounters ce where ce.id = ai_drafts.encounter_id and (ce.user_id = auth.uid() or ce.vet_id = auth.uid()))
    );
  end if;

  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ai_drafts' and policyname = 'ai_drafts_insert_actor') then
    create policy ai_drafts_insert_actor on public.ai_drafts for insert with check (actor_user_id = auth.uid() or is_admin());
  end if;

  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ai_drafts' and policyname = 'ai_drafts_update_reviewer') then
    create policy ai_drafts_update_reviewer on public.ai_drafts for update using (
      is_admin()
      or exists (select 1 from public.clinical_encounters ce where ce.id = ai_drafts.encounter_id and ce.vet_id = auth.uid())
    ) with check (
      is_admin()
      or exists (select 1 from public.clinical_encounters ce where ce.id = ai_drafts.encounter_id and ce.vet_id = auth.uid())
    );
  end if;
end $$;

commit;
