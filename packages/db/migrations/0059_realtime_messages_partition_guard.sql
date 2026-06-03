begin;

create or replace function public.fn_ensure_realtime_messages_partition(p_day date default current_date)
returns void
language plpgsql
security definer
set search_path = public, realtime
as $$
declare
  partition_name text := 'messages_' || to_char(p_day, 'YYYY_MM_DD');
  partition_start timestamp := p_day::timestamp;
  partition_end timestamp := (p_day + 1)::timestamp;
begin
  if to_regclass('realtime.' || partition_name) is null then
    execute format(
      'create table if not exists realtime.%I partition of realtime.messages for values from (%L) to (%L)',
      partition_name,
      partition_start,
      partition_end
    );
  end if;
end;
$$;

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

  perform public.fn_ensure_realtime_messages_partition(current_date);

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

commit;