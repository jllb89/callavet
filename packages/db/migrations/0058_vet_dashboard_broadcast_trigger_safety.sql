begin;

create or replace function public.fn_broadcast_chat_session_dashboard_change()
returns trigger
language plpgsql
security definer
set search_path = public, realtime
as $$
begin
  if tg_op = 'INSERT' then
    if new.vet_id is not null then
      perform public.fn_emit_vet_dashboard_broadcast(new.vet_id, tg_table_name, tg_op, new.id, null);
    end if;
    return null;
  end if;

  if tg_op = 'UPDATE' then
    if new.vet_id is not null then
      perform public.fn_emit_vet_dashboard_broadcast(new.vet_id, tg_table_name, tg_op, new.id, null);
    end if;
    if old.vet_id is not null and old.vet_id is distinct from new.vet_id then
      perform public.fn_emit_vet_dashboard_broadcast(old.vet_id, tg_table_name, tg_op, old.id, null);
    end if;
    return null;
  end if;

  if tg_op = 'DELETE' and old.vet_id is not null then
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
  if tg_op = 'INSERT' then
    if new.vet_id is not null then
      perform public.fn_emit_vet_dashboard_broadcast(new.vet_id, tg_table_name, tg_op, new.session_id, new.id);
    end if;
    return null;
  end if;

  if tg_op = 'UPDATE' then
    if new.vet_id is not null then
      perform public.fn_emit_vet_dashboard_broadcast(new.vet_id, tg_table_name, tg_op, new.session_id, new.id);
    end if;
    if old.vet_id is not null and old.vet_id is distinct from new.vet_id then
      perform public.fn_emit_vet_dashboard_broadcast(old.vet_id, tg_table_name, tg_op, old.session_id, old.id);
    end if;
    return null;
  end if;

  if tg_op = 'DELETE' and old.vet_id is not null then
    perform public.fn_emit_vet_dashboard_broadcast(old.vet_id, tg_table_name, tg_op, old.session_id, old.id);
  end if;

  return null;
end;
$$;

commit;