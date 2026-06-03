begin;

alter table public.chat_sessions
  add column if not exists specialty_id uuid references public.vet_specialties(id) on delete set null,
  add column if not exists priority text check (priority in ('routine', 'urgent', 'emergency'));

create index if not exists chat_sessions_specialty_idx
  on public.chat_sessions (specialty_id)
  where specialty_id is not null;

create index if not exists chat_sessions_priority_active_idx
  on public.chat_sessions (priority, started_at desc)
  where priority is not null and status = 'active';

commit;