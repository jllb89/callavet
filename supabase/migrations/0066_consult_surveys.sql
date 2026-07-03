begin;

create table if not exists public.consult_surveys (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.chat_sessions(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  vet_id uuid references public.vets(id) on delete set null,
  pet_id uuid references public.pets(id) on delete set null,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'deferred', 'completed', 'dismissed')),
  prompted_at timestamptz,
  accepted_at timestamptz,
  declined_at timestamptz,
  deferred_at timestamptz,
  next_prompt_at timestamptz,
  completed_at timestamptz,
  vet_assistance_score int check (vet_assistance_score between 1 and 5),
  app_service_score int check (app_service_score between 1 and 5),
  open_feedback text,
  source text not null default 'post_call_chat' check (source in ('post_call_chat', 'pending_card', 'api', 'admin')),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (session_id, user_id),
  check (jsonb_typeof(metadata) = 'object')
);

create index if not exists consult_surveys_user_status_due_idx
  on public.consult_surveys (user_id, status, next_prompt_at)
  where status in ('pending', 'deferred');

create index if not exists consult_surveys_session_user_idx
  on public.consult_surveys (session_id, user_id);

create index if not exists consult_surveys_vet_completed_idx
  on public.consult_surveys (vet_id, completed_at desc)
  where completed_at is not null;

create index if not exists consult_surveys_pet_idx
  on public.consult_surveys (pet_id, created_at desc)
  where pet_id is not null;

alter table public.consult_surveys enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public'
       and tablename = 'consult_surveys'
       and policyname = 'consult_surveys_owner_admin_select'
  ) then
    create policy consult_surveys_owner_admin_select on public.consult_surveys
      for select
      using (user_id = auth.uid() or is_admin());
  end if;

  if not exists (
    select 1 from pg_policies
     where schemaname = 'public'
       and tablename = 'consult_surveys'
       and policyname = 'consult_surveys_owner_admin_insert'
  ) then
    create policy consult_surveys_owner_admin_insert on public.consult_surveys
      for insert
      with check (user_id = auth.uid() or is_admin());
  end if;

  if not exists (
    select 1 from pg_policies
     where schemaname = 'public'
       and tablename = 'consult_surveys'
       and policyname = 'consult_surveys_owner_admin_update'
  ) then
    create policy consult_surveys_owner_admin_update on public.consult_surveys
      for update
      using (user_id = auth.uid() or is_admin())
      with check (user_id = auth.uid() or is_admin());
  end if;
end $$;

create or replace function public.trg_consult_surveys_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_consult_surveys_set_updated_at on public.consult_surveys;
create trigger trg_consult_surveys_set_updated_at
before update on public.consult_surveys
for each row
execute function public.trg_consult_surveys_set_updated_at();

comment on table public.consult_surveys is 'Structured owner post-consult survey workflow. Vet score feeds ratings; app score remains owner/admin row-level feedback.';
comment on column public.consult_surveys.vet_assistance_score is 'Owner score for veterinarian assistance. Upserted into ratings.score on completion.';
comment on column public.consult_surveys.app_service_score is 'Owner score for the app/service experience. Not included in vet public rating averages.';
comment on column public.consult_surveys.next_prompt_at is 'When deferred survey should be shown again in-app.';

commit;