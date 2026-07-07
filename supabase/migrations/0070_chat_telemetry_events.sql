-- Chat V2 client reliability telemetry: low-cardinality events without message body content.

begin;

create table if not exists public.chat_telemetry_events (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.chat_sessions(id) on delete cascade,
  actor_user_id uuid references public.users(id) on delete set null,
  actor_role text not null check (actor_role in ('user', 'vet')),
  event_type text not null check (event_type in (
    'send_started',
    'send_completed',
    'send_failed',
    'upload_started',
    'upload_progress',
    'upload_completed',
    'upload_failed',
    'realtime_reconnect',
    'realtime_catchup',
    'playback_refresh',
    'read_receipt_sent'
  )),
  client_key text,
  message_id uuid,
  attachment_id uuid,
  duration_ms integer check (duration_ms is null or duration_ms >= 0),
  value_ms integer check (value_ms is null or value_ms >= 0),
  value_count integer check (value_count is null or value_count >= 0),
  error_code text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint chat_telemetry_client_key_length check (client_key is null or length(client_key) <= 128),
  constraint chat_telemetry_error_code_length check (error_code is null or length(error_code) <= 120)
);

create index if not exists chat_telemetry_events_session_created_idx
  on public.chat_telemetry_events (session_id, created_at desc);

create index if not exists chat_telemetry_events_type_created_idx
  on public.chat_telemetry_events (event_type, created_at desc);

create index if not exists chat_telemetry_events_actor_created_idx
  on public.chat_telemetry_events (actor_role, created_at desc);

alter table public.chat_telemetry_events enable row level security;

do $$
begin
  if not exists (
    select 1
      from pg_policies
     where schemaname = 'public'
       and tablename = 'chat_telemetry_events'
       and policyname = 'chat_telemetry_select_participants'
  ) then
    create policy chat_telemetry_select_participants
      on public.chat_telemetry_events
      for select
      using (
        exists (
          select 1
            from public.chat_sessions s
           where s.id = chat_telemetry_events.session_id
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
       and tablename = 'chat_telemetry_events'
       and policyname = 'chat_telemetry_insert_participants'
  ) then
    create policy chat_telemetry_insert_participants
      on public.chat_telemetry_events
      for insert
      with check (
        actor_user_id = auth.uid()
        and exists (
          select 1
            from public.chat_sessions s
           where s.id = chat_telemetry_events.session_id
             and (
               (chat_telemetry_events.actor_role = 'user' and s.user_id = auth.uid())
               or (chat_telemetry_events.actor_role = 'vet' and s.vet_id = auth.uid())
             )
        )
      );
  end if;
end $$;

comment on table public.chat_telemetry_events is 'Client-emitted chat reliability telemetry. Does not store message body content or private storage paths.';
comment on column public.chat_telemetry_events.metadata is 'Low-cardinality JSON metadata only: counts, booleans, statuses, and coarse labels. No message bodies or private storage paths.';

commit;
