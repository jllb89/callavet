begin;

alter table realtime.messages enable row level security;

do $$
begin
  if not exists (
    select 1
      from pg_policies
     where schemaname = 'realtime'
       and tablename = 'messages'
       and policyname = 'vet_dashboard_private_broadcast_select'
  ) then
    create policy vet_dashboard_private_broadcast_select on realtime.messages
      for select
      to authenticated
      using (
        private = true
        and (
          topic = 'vet-dashboard:' || auth.uid()::text
          or exists (
            select 1
              from public.users u
             where u.id = auth.uid()
               and u.role = 'admin'
               and topic like 'vet-dashboard:%'
          )
        )
      );
  end if;
end $$;

create or replace function public.fn_emit_vet_dashboard_broadcast(
  p_vet_id uuid,
  p_table_name text,
  p_operation text,
  p_session_id uuid default null,
  p_appointment_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, realtime
as $$
begin
  if p_vet_id is null then
    return;
  end if;

  perform realtime.send(
    jsonb_build_object(
      'type', 'vet_dashboard',
      'action', lower(p_operation),
      'table', p_table_name,
      'sessionId', p_session_id,
      'appointmentId', p_appointment_id
    ),
    'dashboard_changed',
    'vet-dashboard:' || p_vet_id::text,
    true
  );
end;
$$;

create or replace function public.fn_broadcast_chat_session_dashboard_change()
returns trigger
language plpgsql
security definer
set search_path = public, realtime
as $$
begin
  if tg_op in ('INSERT', 'UPDATE') and new.vet_id is not null then
    perform public.fn_emit_vet_dashboard_broadcast(new.vet_id, tg_table_name, tg_op, new.id, null);
  end if;

  if tg_op in ('UPDATE', 'DELETE') and old.vet_id is not null and (tg_op = 'DELETE' or old.vet_id is distinct from new.vet_id) then
    perform public.fn_emit_vet_dashboard_broadcast(old.vet_id, tg_table_name, tg_op, old.id, null);
  end if;

  return null;
end;
$$;

create or replace function public.fn_broadcast_appointment_dashboard_change()
returns trigger
language plpgsql
security definer
set search_path = public, realtime
as $$
begin
  if tg_op in ('INSERT', 'UPDATE') and new.vet_id is not null then
    perform public.fn_emit_vet_dashboard_broadcast(new.vet_id, tg_table_name, tg_op, new.session_id, new.id);
  end if;

  if tg_op in ('UPDATE', 'DELETE') and old.vet_id is not null and (tg_op = 'DELETE' or old.vet_id is distinct from new.vet_id) then
    perform public.fn_emit_vet_dashboard_broadcast(old.vet_id, tg_table_name, tg_op, old.session_id, old.id);
  end if;

  return null;
end;
$$;

create or replace function public.fn_broadcast_video_lifecycle_dashboard_change()
returns trigger
language plpgsql
security definer
set search_path = public, realtime
as $$
declare
  target_session_id uuid;
  target_vet_id uuid;
begin
  target_session_id := case when tg_op = 'DELETE' then old.session_id else new.session_id end;

  select s.vet_id
    into target_vet_id
    from public.chat_sessions s
   where s.id = target_session_id;

  if target_vet_id is not null then
    perform public.fn_emit_vet_dashboard_broadcast(target_vet_id, tg_table_name, tg_op, target_session_id, null);
  end if;

  return null;
end;
$$;

drop trigger if exists trg_chat_sessions_vet_dashboard_broadcast on public.chat_sessions;
create trigger trg_chat_sessions_vet_dashboard_broadcast
  after insert or update or delete on public.chat_sessions
  for each row execute function public.fn_broadcast_chat_session_dashboard_change();

drop trigger if exists trg_appointments_vet_dashboard_broadcast on public.appointments;
create trigger trg_appointments_vet_dashboard_broadcast
  after insert or update or delete on public.appointments
  for each row execute function public.fn_broadcast_appointment_dashboard_change();

drop trigger if exists trg_video_session_lifecycle_vet_dashboard_broadcast on public.video_session_lifecycle;
create trigger trg_video_session_lifecycle_vet_dashboard_broadcast
  after insert or update or delete on public.video_session_lifecycle
  for each row execute function public.fn_broadcast_video_lifecycle_dashboard_change();

commit;