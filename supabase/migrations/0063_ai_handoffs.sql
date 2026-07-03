begin;

create table if not exists public.ai_handoffs (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.chat_sessions(id) on delete cascade,
  ai_event_id uuid references public.ai_events(id) on delete set null,
  source_ai_event_id uuid references public.ai_events(id) on delete set null,
  actor_user_id uuid references public.users(id) on delete set null,
  pet_id uuid references public.pets(id) on delete set null,
  vet_id uuid references public.vets(id) on delete set null,
  specialty_id uuid references public.vet_specialties(id) on delete set null,
  urgency text not null default 'routine' check (urgency in ('routine', 'urgent', 'emergency')),
  summary_text text not null,
  reported_signs jsonb not null default '[]'::jsonb,
  red_flags jsonb not null default '[]'::jsonb,
  questions_answered jsonb not null default '[]'::jsonb,
  questions_unanswered jsonb not null default '[]'::jsonb,
  recommended_first_checks jsonb not null default '[]'::jsonb,
  source_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (session_id),
  check (jsonb_typeof(reported_signs) = 'array'),
  check (jsonb_typeof(red_flags) = 'array'),
  check (jsonb_typeof(questions_answered) = 'array'),
  check (jsonb_typeof(questions_unanswered) = 'array'),
  check (jsonb_typeof(recommended_first_checks) = 'array')
);

create index if not exists ai_handoffs_actor_idx
  on public.ai_handoffs (actor_user_id, created_at desc);

create index if not exists ai_handoffs_session_idx
  on public.ai_handoffs (session_id, created_at desc);

create index if not exists ai_handoffs_pet_idx
  on public.ai_handoffs (pet_id, created_at desc)
  where pet_id is not null;

create index if not exists ai_handoffs_vet_idx
  on public.ai_handoffs (vet_id, created_at desc)
  where vet_id is not null;

alter table public.ai_handoffs enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public'
       and tablename = 'ai_handoffs'
       and policyname = 'ai_handoffs_select_participants'
  ) then
    create policy ai_handoffs_select_participants on public.ai_handoffs
      for select
      using (
        actor_user_id = auth.uid()
        or is_admin()
        or exists (
          select 1
            from public.chat_sessions s
           where s.id = ai_handoffs.session_id
             and (s.user_id = auth.uid() or s.vet_id = auth.uid())
        )
      );
  end if;

  if not exists (
    select 1 from pg_policies
     where schemaname = 'public'
       and tablename = 'ai_handoffs'
       and policyname = 'ai_handoffs_insert_actor'
  ) then
    create policy ai_handoffs_insert_actor on public.ai_handoffs
      for insert
      with check (actor_user_id = auth.uid() or is_admin());
  end if;

  if not exists (
    select 1 from pg_policies
     where schemaname = 'public'
       and tablename = 'ai_handoffs'
       and policyname = 'ai_handoffs_update_actor'
  ) then
    create policy ai_handoffs_update_actor on public.ai_handoffs
      for update
      using (actor_user_id = auth.uid() or is_admin())
      with check (actor_user_id = auth.uid() or is_admin());
  end if;
end $$;

comment on table public.ai_handoffs is 'AI-generated, non-diagnostic pre-consult handoff context for chat and video sessions.';
comment on column public.ai_handoffs.summary_text is 'Concise AI-generated handoff summary for the human veterinarian; not a diagnosis.';
comment on column public.ai_handoffs.recommended_first_checks is 'AI-generated clinician-facing checks to confirm, not owner treatment instructions.';

commit;