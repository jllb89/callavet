-- Chat consultation message attachments: private media storage metadata.

begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'chat-media',
  'chat-media',
  false,
  52428800,
  array[
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/heic',
    'image/heif',
    'video/mp4',
    'video/quicktime',
    'audio/aac',
    'audio/mp4',
    'audio/mpeg',
    'audio/wav',
    'audio/webm',
    'audio/x-m4a'
  ]::text[]
)
on conflict (id) do update
   set public = false,
       file_size_limit = excluded.file_size_limit,
       allowed_mime_types = excluded.allowed_mime_types;

create table if not exists public.message_attachments (
  id uuid primary key default gen_random_uuid(),
  message_id uuid references public.messages(id) on delete cascade,
  session_id uuid not null references public.chat_sessions(id) on delete cascade,
  uploaded_by uuid references public.users(id) on delete set null,
  kind text not null check (kind in ('image', 'video', 'voice')),
  storage_bucket text not null default 'chat-media',
  storage_path text not null,
  content_type text not null,
  byte_size bigint not null check (byte_size > 0),
  width integer check (width is null or width > 0),
  height integer check (height is null or height > 0),
  duration_ms integer check (duration_ms is null or duration_ms > 0),
  thumbnail_path text,
  waveform jsonb,
  status text not null default 'pending' check (status in ('pending', 'ready', 'failed', 'removed')),
  transcript_text text,
  transcript_status text not null default 'not_requested' check (transcript_status in ('not_requested', 'pending', 'ready', 'failed')),
  metadata jsonb not null default '{}'::jsonb,
  deleted_at timestamptz,
  deleted_by uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint message_attachments_message_session_required check (message_id is not null or status in ('pending', 'failed')),
  constraint message_attachments_image_limits check (kind <> 'image' or byte_size <= 8388608),
  constraint message_attachments_video_limits check (kind <> 'video' or byte_size <= 52428800),
  constraint message_attachments_voice_limits check (kind <> 'voice' or (byte_size <= 15728640 and coalesce(duration_ms, 0) <= 300000))
);

create unique index if not exists message_attachments_storage_unique
  on public.message_attachments (storage_bucket, storage_path);

create index if not exists message_attachments_message_idx
  on public.message_attachments (message_id, created_at asc)
  where message_id is not null and deleted_at is null;

create index if not exists message_attachments_session_idx
  on public.message_attachments (session_id, created_at desc)
  where deleted_at is null;

create index if not exists message_attachments_uploader_pending_idx
  on public.message_attachments (uploaded_by, session_id, created_at desc)
  where message_id is null and status = 'pending' and deleted_at is null;

alter table public.message_attachments enable row level security;

do $$
begin
  if not exists (
    select 1
      from pg_policies
     where schemaname = 'public'
       and tablename = 'message_attachments'
       and policyname = 'message_attachments_select_participants'
  ) then
    create policy message_attachments_select_participants
      on public.message_attachments
      for select
      using (
        exists (
          select 1
            from public.chat_sessions s
           where s.id = message_attachments.session_id
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
       and tablename = 'message_attachments'
       and policyname = 'message_attachments_insert_participants'
  ) then
    create policy message_attachments_insert_participants
      on public.message_attachments
      for insert
      with check (
        uploaded_by = auth.uid()
        and exists (
          select 1
            from public.chat_sessions s
           where s.id = message_attachments.session_id
             and s.status = 'active'
             and (s.user_id = auth.uid() or s.vet_id = auth.uid())
        )
      );
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
      from pg_policies
     where schemaname = 'public'
       and tablename = 'message_attachments'
       and policyname = 'message_attachments_update_sender_or_admin'
  ) then
    create policy message_attachments_update_sender_or_admin
      on public.message_attachments
      for update
      using (uploaded_by = auth.uid() or public.is_admin())
      with check (uploaded_by = auth.uid() or public.is_admin());
  end if;
end $$;

create or replace function public.trg_message_attachments_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_message_attachments_set_updated_at on public.message_attachments;
create trigger trg_message_attachments_set_updated_at
before update on public.message_attachments
for each row
execute function public.trg_message_attachments_set_updated_at();

commit;