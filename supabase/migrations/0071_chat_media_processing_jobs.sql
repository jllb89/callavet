-- Chat media processing jobs for thumbnails, waveform, transcription, and safety scans.

begin;

create table if not exists public.chat_media_processing_jobs (
  id uuid primary key default gen_random_uuid(),
  attachment_id uuid not null references public.message_attachments(id) on delete cascade,
  session_id uuid not null references public.chat_sessions(id) on delete cascade,
  task text not null check (task in ('thumbnail', 'waveform', 'transcription', 'safety_scan')),
  status text not null default 'pending' check (status in ('pending', 'running', 'succeeded', 'failed', 'skipped')),
  attempts integer not null default 0 check (attempts >= 0),
  error_code text,
  result jsonb not null default '{}'::jsonb,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (attachment_id, task)
);

create index if not exists chat_media_processing_jobs_status_idx
  on public.chat_media_processing_jobs (status, created_at asc)
  where status in ('pending', 'failed');

create index if not exists chat_media_processing_jobs_session_idx
  on public.chat_media_processing_jobs (session_id, created_at desc);

alter table public.chat_media_processing_jobs enable row level security;

do $$
begin
  if not exists (
    select 1
      from pg_policies
     where schemaname = 'public'
       and tablename = 'chat_media_processing_jobs'
       and policyname = 'chat_media_processing_jobs_select_participants'
  ) then
    create policy chat_media_processing_jobs_select_participants
      on public.chat_media_processing_jobs
      for select
      using (
        exists (
          select 1
            from public.chat_sessions s
           where s.id = chat_media_processing_jobs.session_id
             and (s.user_id = auth.uid() or s.vet_id = auth.uid())
        )
        or public.is_admin()
      );
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
      from pg_policies
     where schemaname = 'public'
       and tablename = 'chat_media_processing_jobs'
       and policyname = 'chat_media_processing_jobs_admin_write'
  ) then
    create policy chat_media_processing_jobs_admin_write
      on public.chat_media_processing_jobs
      for all
      using (public.is_admin())
      with check (public.is_admin());
  end if;
end $$;

create or replace function public.trg_chat_media_processing_jobs_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_chat_media_processing_jobs_set_updated_at on public.chat_media_processing_jobs;
create trigger trg_chat_media_processing_jobs_set_updated_at
before update on public.chat_media_processing_jobs
for each row
execute function public.trg_chat_media_processing_jobs_set_updated_at();

create or replace function public.enqueue_chat_media_processing_jobs()
returns trigger
language plpgsql
as $$
declare
  should_enqueue boolean := false;
begin
  if new.status = 'ready' and tg_op = 'INSERT' then
    should_enqueue := true;
  elsif new.status = 'ready' and tg_op = 'UPDATE' then
    should_enqueue := old.status is distinct from new.status or old.message_id is distinct from new.message_id;
  end if;

  if should_enqueue then
    insert into public.chat_media_processing_jobs (attachment_id, session_id, task)
    values (new.id, new.session_id, 'safety_scan')
    on conflict (attachment_id, task) do nothing;

    if new.kind in ('image', 'video') then
      insert into public.chat_media_processing_jobs (attachment_id, session_id, task)
      values (new.id, new.session_id, 'thumbnail')
      on conflict (attachment_id, task) do nothing;
    end if;

    if new.kind = 'voice' then
      insert into public.chat_media_processing_jobs (attachment_id, session_id, task)
      values (new.id, new.session_id, 'waveform'),
             (new.id, new.session_id, 'transcription')
      on conflict (attachment_id, task) do nothing;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enqueue_chat_media_processing_jobs on public.message_attachments;
create trigger trg_enqueue_chat_media_processing_jobs
after insert or update of status, message_id
on public.message_attachments
for each row
execute function public.enqueue_chat_media_processing_jobs();

insert into public.chat_media_processing_jobs (attachment_id, session_id, task)
select a.id, a.session_id, task.task
  from public.message_attachments a
  cross join lateral (
    values
      ('safety_scan'),
      (case when a.kind in ('image', 'video') then 'thumbnail' end),
      (case when a.kind = 'voice' then 'waveform' end),
      (case when a.kind = 'voice' then 'transcription' end)
  ) as task(task)
 where a.status = 'ready'
   and a.deleted_at is null
   and task.task is not null
on conflict (attachment_id, task) do nothing;

comment on table public.chat_media_processing_jobs is 'Operational queue for chat attachment processing. Results must not include private storage paths in user-facing exports.';
comment on column public.chat_media_processing_jobs.result is 'Structured processing result metadata only; do not store raw media, message bodies, or private signed URLs here.';

commit;