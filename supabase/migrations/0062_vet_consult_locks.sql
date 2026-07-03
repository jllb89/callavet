begin;

create table if not exists public.vet_consult_locks (
  vet_id uuid primary key references public.vets(id) on delete cascade,
  session_id uuid not null references public.chat_sessions(id) on delete cascade,
  mode text not null check (mode in ('chat', 'video')),
  locked_at timestamptz not null default now(),
  expires_at timestamptz not null,
  released_at timestamptz,
  reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (expires_at > locked_at)
);

create index if not exists vet_consult_locks_active_idx
  on public.vet_consult_locks (expires_at, mode, session_id)
  where released_at is null;

create index if not exists vet_consult_locks_session_idx
  on public.vet_consult_locks (session_id)
  where released_at is null;

alter table public.vet_consult_locks enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public'
       and tablename = 'vet_consult_locks'
       and policyname = 'vet_consult_locks_select_participants'
  ) then
    create policy vet_consult_locks_select_participants on public.vet_consult_locks
      for select
      using (
        is_admin()
        or vet_id = auth.uid()
        or exists (
          select 1
            from public.chat_sessions s
           where s.id = vet_consult_locks.session_id
             and s.user_id = auth.uid()
        )
      );
  end if;

  if not exists (
    select 1 from pg_policies
     where schemaname = 'public'
       and tablename = 'vet_consult_locks'
       and policyname = 'vet_consult_locks_admin_all'
  ) then
    create policy vet_consult_locks_admin_all on public.vet_consult_locks
      for all
      using (is_admin())
      with check (is_admin());
  end if;
end $$;

create or replace function public.fn_release_vet_consult_lock(
  p_session_id uuid,
  p_reason text default 'released'
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  affected integer := 0;
begin
  update public.vet_consult_locks
     set released_at = coalesce(released_at, now()),
         reason = coalesce(p_reason, reason, 'released'),
         updated_at = now()
   where session_id = p_session_id
     and released_at is null;

  get diagnostics affected = row_count;
  return affected;
end;
$$;

create or replace function public.fn_release_expired_vet_consult_locks()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  affected integer := 0;
begin
  update public.vet_consult_locks
     set released_at = coalesce(released_at, now()),
         reason = coalesce(reason, 'expired'),
         updated_at = now()
   where released_at is null
     and expires_at < now();

  get diagnostics affected = row_count;
  return affected;
end;
$$;

comment on table public.vet_consult_locks is 'Active vet consult locks used to prevent assigning one vet to multiple simultaneous consults.';
comment on function public.fn_release_vet_consult_lock(uuid, text) is 'Releases any active vet consult lock for a session.';
comment on function public.fn_release_expired_vet_consult_locks() is 'Marks stale vet consult locks as released after expires_at.';

commit;