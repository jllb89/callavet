begin;

alter table realtime.messages enable row level security;

do $$
begin
  if not exists (
    select 1
      from pg_policies
     where schemaname = 'realtime'
       and tablename = 'messages'
       and policyname = 'consult_room_private_broadcast_select'
  ) then
    create policy consult_room_private_broadcast_select on realtime.messages
      for select
      to authenticated
      using (
        private = true
        and topic ~ '^consult-room:[0-9a-fA-F-]{36}$'
        and (
          exists (
            select 1
              from public.chat_sessions s
             where s.id = substring(topic from 14)::uuid
               and (s.user_id = auth.uid() or s.vet_id = auth.uid())
          )
          or exists (
            select 1
              from public.users u
             where u.id = auth.uid()
               and u.role = 'admin'
          )
        )
      );
  end if;
end $$;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if to_regclass('public.consult_surveys') is not null
       and not exists (
         select 1
           from pg_publication_tables
          where pubname = 'supabase_realtime'
            and schemaname = 'public'
            and tablename = 'consult_surveys'
       ) then
      alter publication supabase_realtime add table public.consult_surveys;
    end if;
  end if;
end $$;

create or replace function public.fn_emit_consult_room_broadcast(
  p_session_id uuid,
  p_event text,
  p_payload jsonb
)
returns void
language plpgsql
security definer
set search_path = public, realtime
as $$
begin
  if p_session_id is null or nullif(btrim(coalesce(p_event, '')), '') is null then
    return;
  end if;

  perform realtime.send(
    coalesce(p_payload, '{}'::jsonb),
    p_event,
    'consult-room:' || p_session_id::text,
    true
  );
end;
$$;

create or replace view public.chat_consultation_realtime_health_24h
with (security_invoker = true) as
with recent_sessions as (
  select s.id,
         s.user_id,
         s.vet_id,
         s.pet_id,
         s.status,
         s.created_at,
         s.updated_at,
         s.ended_at
    from public.chat_sessions s
   where coalesce(s.mode, 'chat') = 'chat'
     and s.created_at >= now() - interval '24 hours'
), first_owner_message as (
  select m.session_id, min(m.created_at) as first_owner_at
    from public.messages m
    join recent_sessions rs on rs.id = m.session_id
   where m.role = 'user'
   group by m.session_id
), first_vet_message as (
  select m.session_id, min(m.created_at) as first_vet_at
    from public.messages m
    join recent_sessions rs on rs.id = m.session_id
   where m.role = 'vet'
   group by m.session_id
), message_counts as (
  select m.session_id, count(*)::int as message_count
    from public.messages m
    join recent_sessions rs on rs.id = m.session_id
   where m.deleted_at is null
   group by m.session_id
)
select count(*)::int as sessions_created_24h,
       count(*) filter (where rs.status = 'active')::int as active_sessions_24h,
       count(*) filter (where rs.status = 'completed')::int as completed_sessions_24h,
       count(*) filter (where rs.status in ('canceled', 'no_show'))::int as not_completed_sessions_24h,
       count(*) filter (where fom.first_owner_at is not null)::int as sessions_with_owner_message_24h,
       count(*) filter (where fvm.first_vet_at is not null)::int as sessions_with_vet_response_24h,
       count(*) filter (where coalesce(mc.message_count, 0) = 0 and rs.status <> 'active')::int as abandoned_without_messages_24h,
       coalesce(sum(coalesce(mc.message_count, 0)), 0)::int as messages_in_recent_sessions_24h,
       round(avg(extract(epoch from (fvm.first_vet_at - fom.first_owner_at))) filter (where fom.first_owner_at is not null and fvm.first_vet_at is not null)::numeric, 2) as avg_first_vet_response_seconds_24h
  from recent_sessions rs
  left join first_owner_message fom on fom.session_id = rs.id
  left join first_vet_message fvm on fvm.session_id = rs.id
  left join message_counts mc on mc.session_id = rs.id;

create or replace view public.chat_consultation_realtime_sessions_24h
with (security_invoker = true) as
select s.id as session_id,
       s.user_id,
       u.full_name as owner_name,
       s.vet_id,
       vu.full_name as vet_name,
       s.pet_id,
       p.name as pet_name,
       s.status,
       s.priority,
       s.created_at,
       s.updated_at,
       s.ended_at,
       count(m.id)::int as message_count,
       min(m.created_at) filter (where m.role = 'user') as first_owner_message_at,
       min(m.created_at) filter (where m.role = 'vet') as first_vet_response_at,
       count(m.id) filter (where m.role = 'user')::int as owner_message_count,
       count(m.id) filter (where m.role = 'vet')::int as vet_message_count,
       count(distinct mr.message_id) filter (where mr.read_at is not null)::int as read_receipt_message_count,
       cs.status as survey_status,
       cs.prompted_at as survey_prompted_at,
       cs.completed_at as survey_completed_at
  from public.chat_sessions s
  left join public.users u on u.id = s.user_id
  left join public.users vu on vu.id = s.vet_id
  left join public.pets p on p.id = s.pet_id
  left join public.messages m on m.session_id = s.id and m.deleted_at is null
  left join public.message_receipts mr on mr.message_id = m.id
  left join public.consult_surveys cs on cs.session_id = s.id and cs.user_id = s.user_id
 where coalesce(s.mode, 'chat') = 'chat'
   and s.created_at >= now() - interval '24 hours'
 group by s.id, u.full_name, vu.full_name, p.name, cs.status, cs.prompted_at, cs.completed_at;

comment on view public.chat_consultation_realtime_health_24h is '24-hour chat consultation realtime health rollup for sessions, first messages, response time, and abandonment.';
comment on view public.chat_consultation_realtime_sessions_24h is 'Session-level 24-hour chat consultation realtime observability with message, receipt, and survey state.';

commit;
