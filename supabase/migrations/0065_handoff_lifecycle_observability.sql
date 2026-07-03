begin;

create or replace view public.active_vet_consult_lock_observability
with (security_invoker = true) as
select
  l.vet_id,
  vu.full_name as vet_name,
  l.session_id,
  l.mode,
  l.reason as lock_reason,
  l.locked_at,
  l.expires_at,
  now() - l.locked_at as lock_age,
  l.expires_at - now() as expires_in,
  s.user_id as owner_user_id,
  ou.full_name as owner_name,
  s.pet_id,
  p.name as pet_name,
  s.specialty_id,
  vs.name as specialty_name,
  s.priority as session_priority,
  s.status as session_status,
  s.started_at as session_started_at,
  l.updated_at as lock_updated_at
from public.vet_consult_locks l
join public.chat_sessions s on s.id = l.session_id
left join public.users vu on vu.id = l.vet_id
left join public.users ou on ou.id = s.user_id
left join public.pets p on p.id = s.pet_id
left join public.vet_specialties vs on vs.id = s.specialty_id
where l.released_at is null
  and l.expires_at > now();

create or replace view public.vet_consult_lock_recent_events
with (security_invoker = true) as
select
  l.vet_id,
  vu.full_name as vet_name,
  l.session_id,
  l.mode,
  l.reason,
  case
    when l.released_at is not null then 'released'
    when l.expires_at <= now() then 'expired_unreleased'
    else 'active'
  end as lock_state,
  l.locked_at,
  l.expires_at,
  l.released_at,
  l.updated_at,
  s.status as session_status,
  s.started_at as session_started_at,
  p.name as pet_name
from public.vet_consult_locks l
join public.chat_sessions s on s.id = l.session_id
left join public.users vu on vu.id = l.vet_id
left join public.pets p on p.id = s.pet_id
where l.created_at >= now() - interval '7 days'
   or l.released_at >= now() - interval '7 days'
order by coalesce(l.released_at, l.updated_at, l.locked_at) desc;

create or replace view public.ai_handoff_session_observability
with (security_invoker = true) as
with latest_handoff as (
  select distinct on (h.session_id)
         h.*
    from public.ai_handoffs h
   order by h.session_id, h.created_at desc
),
latest_event as (
  select distinct on (e.session_id)
         e.id,
         e.session_id,
         e.status,
         e.error_text,
         e.latency_ms,
         e.created_at,
         e.updated_at,
         e.response_payload
    from public.ai_events e
   where e.event_type = 'ai.handoff.generate'
   order by e.session_id, e.created_at desc
),
event_counts as (
  select e.session_id,
         count(*)::int as generation_attempts,
         count(*) filter (where e.status = 'succeeded')::int as succeeded_attempts,
         count(*) filter (where e.status = 'failed')::int as failed_attempts
    from public.ai_events e
   where e.event_type = 'ai.handoff.generate'
   group by e.session_id
)
select
  s.id as session_id,
  s.user_id as owner_user_id,
  ou.full_name as owner_name,
  s.vet_id,
  vu.full_name as vet_name,
  s.pet_id,
  p.name as pet_name,
  s.specialty_id,
  vs.name as specialty_name,
  s.mode,
  s.priority,
  s.status as session_status,
  s.started_at,
  h.id as handoff_id,
  h.ai_event_id,
  h.source_ai_event_id,
  h.urgency as handoff_urgency,
  h.created_at as handoff_created_at,
  e.id as latest_generation_event_id,
  e.status as latest_generation_status,
  e.error_text as latest_generation_error,
  e.latency_ms as latest_generation_latency_ms,
  e.created_at as latest_generation_created_at,
  coalesce(c.generation_attempts, 0) as generation_attempts,
  coalesce(c.succeeded_attempts, 0) as succeeded_attempts,
  coalesce(c.failed_attempts, 0) as failed_attempts,
  case
    when h.id is not null then 'created'
    when e.status = 'failed' then 'failed'
    when e.status in ('queued', 'running') then e.status
    when s.status in ('completed', 'canceled', 'no_show') then 'closed_without_handoff'
    when s.started_at is not null and s.started_at < now() - interval '5 minutes' then 'missing'
    else 'pending_or_not_requested'
  end as handoff_state,
  case
    when h.id is not null then null
    when e.status = 'failed' then coalesce(nullif(e.error_text, ''), 'generation_failed')
    when e.status in ('queued', 'running') then 'generation_in_progress'
    when s.status in ('completed', 'canceled', 'no_show') then 'session_closed_before_handoff'
    when coalesce(c.generation_attempts, 0) = 0 then 'no_generation_event'
    else 'handoff_not_persisted'
  end as missing_reason
from public.chat_sessions s
left join latest_handoff h on h.session_id = s.id
left join latest_event e on e.session_id = s.id
left join event_counts c on c.session_id = s.id
left join public.users ou on ou.id = s.user_id
left join public.users vu on vu.id = s.vet_id
left join public.pets p on p.id = s.pet_id
left join public.vet_specialties vs on vs.id = s.specialty_id
where s.mode in ('chat', 'video')
  and s.started_at >= now() - interval '30 days';

create or replace view public.ai_handoff_generation_health_24h
with (security_invoker = true) as
select
  date_trunc('hour', e.created_at) as hour,
  count(*)::int as total_generation_events,
  count(*) filter (where e.status = 'succeeded')::int as succeeded_events,
  count(*) filter (where e.status = 'failed')::int as failed_events,
  count(h.id)::int as persisted_handoffs,
  round(
    100.0 * count(*) filter (where e.status = 'failed') / greatest(count(*), 1),
    2
  ) as failed_percent,
  percentile_disc(0.5) within group (order by e.latency_ms) filter (where e.latency_ms is not null) as p50_latency_ms,
  percentile_disc(0.95) within group (order by e.latency_ms) filter (where e.latency_ms is not null) as p95_latency_ms
from public.ai_events e
left join public.ai_handoffs h on h.ai_event_id = e.id
where e.event_type = 'ai.handoff.generate'
  and e.created_at >= now() - interval '24 hours'
group by date_trunc('hour', e.created_at);

create or replace view public.video_lifecycle_observability
with (security_invoker = true) as
with event_counts as (
  select e.session_id,
         count(*)::int as livekit_event_count,
         max(e.received_at) as last_livekit_event_at,
         max(e.received_at) filter (where e.processed_at is not null) as last_processed_at,
         count(*) filter (where e.processing_error is not null)::int as processing_error_count
    from public.livekit_video_events e
   where e.received_at >= now() - interval '30 days'
   group by e.session_id
),
latest_event as (
  select distinct on (e.session_id)
         e.session_id,
         e.event_type as latest_livekit_event_type,
         e.received_at as latest_livekit_event_at,
         e.processing_error as latest_processing_error
    from public.livekit_video_events e
   order by e.session_id, e.received_at desc
)
select
  s.id as session_id,
  s.user_id as owner_user_id,
  ou.full_name as owner_name,
  s.vet_id,
  vu.full_name as vet_name,
  s.pet_id,
  p.name as pet_name,
  s.specialty_id,
  vs.name as specialty_name,
  s.status as session_status,
  s.priority,
  s.started_at,
  s.ended_at,
  v.room_name,
  v.room_sid,
  v.status as lifecycle_status,
  v.first_room_started_at,
  v.first_participant_joined_at,
  v.owner_joined_at,
  v.host_joined_at,
  v.first_both_joined_at,
  v.last_participant_left_at,
  v.room_finished_at,
  v.end_actor_role,
  v.end_actor_user_id,
  coalesce(v.end_reason, v.safety_reason) as end_reason,
  v.rejoin_eligible_until,
  (v.rejoin_eligible_until is not null and v.rejoin_eligible_until > now()) as rejoin_currently_eligible,
  coalesce(c.livekit_event_count, 0) as livekit_event_count,
  c.last_livekit_event_at,
  c.last_processed_at,
  coalesce(c.processing_error_count, 0) as processing_error_count,
  le.latest_livekit_event_type,
  le.latest_processing_error,
  case
    when v.session_id is null then 'missing_lifecycle_row'
    when v.room_name is not null and coalesce(c.livekit_event_count, 0) = 0 and v.created_at < now() - interval '2 minutes' then 'room_without_livekit_events'
    when v.status in ('pending', 'waiting') and v.created_at < now() - interval '10 minutes' then 'stale_waiting_room'
    when coalesce(c.processing_error_count, 0) > 0 then 'webhook_processing_errors'
    when v.status in ('ended', 'released', 'timed_out', 'forced_ended') then 'closed'
    when v.first_both_joined_at is not null then 'live_or_engaged'
    else 'normal'
  end as lifecycle_health_state,
  case
    when coalesce(v.end_reason, v.safety_reason) is not null then coalesce(v.end_reason, v.safety_reason)
    when le.latest_livekit_event_type is not null then le.latest_livekit_event_type
    when v.room_name is not null then 'room_provisioned'
    else null
  end as why_call_ended_or_current_state
from public.chat_sessions s
left join public.video_session_lifecycle v on v.session_id = s.id
left join event_counts c on c.session_id = s.id
left join latest_event le on le.session_id = s.id
left join public.users ou on ou.id = s.user_id
left join public.users vu on vu.id = s.vet_id
left join public.pets p on p.id = s.pet_id
left join public.vet_specialties vs on vs.id = s.specialty_id
where s.mode = 'video'
  and coalesce(s.started_at, s.created_at) >= now() - interval '30 days';

create or replace view public.video_lifecycle_health_24h
with (security_invoker = true) as
select
  lifecycle_health_state,
  count(*)::int as sessions,
  count(*) filter (where livekit_event_count = 0)::int as sessions_without_livekit_events,
  count(*) filter (where processing_error_count > 0)::int as sessions_with_processing_errors,
  count(*) filter (where end_reason is not null)::int as sessions_with_end_reason,
  count(*) filter (where rejoin_currently_eligible)::int as sessions_rejoin_eligible
from public.video_lifecycle_observability
where coalesce(started_at, room_finished_at, last_livekit_event_at, now()) >= now() - interval '24 hours'
group by lifecycle_health_state;

create or replace view public.recent_video_event_observability
with (security_invoker = true) as
select
  e.id,
  e.received_at,
  e.processed_at,
  e.processing_error,
  e.event_type,
  e.room_name,
  e.room_sid,
  e.session_id,
  s.status as session_status,
  v.status as lifecycle_status,
  coalesce(v.end_reason, v.safety_reason) as end_reason,
  e.participant_identity,
  case
    when e.participant_identity like 'owner:%' then 'owner'
    when e.participant_identity like 'vet:%' then 'vet'
    when e.participant_identity like 'admin:%' then 'admin'
    else null
  end as participant_role,
  e.participant_sid,
  e.received_at - lag(e.received_at) over (partition by e.session_id order by e.received_at) as since_previous_session_event
from public.livekit_video_events e
left join public.chat_sessions s on s.id = e.session_id
left join public.video_session_lifecycle v on v.session_id = e.session_id
where e.received_at >= now() - interval '7 days'
order by e.received_at desc;

comment on view public.active_vet_consult_lock_observability is 'Active vet lock view answering who is busy, why, since when, and which session owns the lock.';
comment on view public.vet_consult_lock_recent_events is 'Recent vet consult lock transitions for operational review.';
comment on view public.ai_handoff_session_observability is 'Recent consult sessions with AI handoff state and missing/failure reason.';
comment on view public.ai_handoff_generation_health_24h is 'Hourly 24-hour AI handoff generation health.';
comment on view public.video_lifecycle_observability is 'Recent video sessions with lifecycle, LiveKit event, end reason, and rejoin health.';
comment on view public.video_lifecycle_health_24h is '24-hour aggregate health of video lifecycle states and webhook coverage.';
comment on view public.recent_video_event_observability is 'Recent LiveKit events joined to session lifecycle state for admin smoke checks.';

commit;