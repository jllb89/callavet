begin;

create or replace view public.consult_survey_pending_observability
with (security_invoker = true) as
select
  cs.id as survey_id,
  cs.session_id,
  cs.user_id,
  u.full_name as owner_name,
  cs.vet_id,
  vu.full_name as vet_name,
  cs.pet_id,
  p.name as pet_name,
  s.mode,
  s.status as session_status,
  cs.status as survey_status,
  cs.source,
  cs.prompted_at,
  cs.deferred_at,
  cs.next_prompt_at,
  cs.created_at,
  cs.updated_at,
  now() - cs.created_at as survey_age,
  cs.next_prompt_at is null or cs.next_prompt_at <= now() as is_due,
  case
    when cs.status = 'pending' then 'pending_first_prompt'
    when cs.status = 'deferred' and cs.next_prompt_at <= now() then 'deferred_due'
    when cs.status = 'deferred' then 'deferred_waiting'
    else cs.status
  end as prompt_state
from public.consult_surveys cs
join public.chat_sessions s on s.id = cs.session_id
left join public.users u on u.id = cs.user_id
left join public.users vu on vu.id = cs.vet_id
left join public.pets p on p.id = cs.pet_id
where cs.status in ('pending', 'deferred');

create or replace view public.consult_survey_completion_health_24h
with (security_invoker = true) as
select
  date_trunc('hour', coalesce(cs.completed_at, cs.updated_at, cs.created_at)) as hour,
  count(*)::int as touched_surveys,
  count(*) filter (where cs.status = 'pending')::int as pending_surveys,
  count(*) filter (where cs.status = 'accepted')::int as accepted_surveys,
  count(*) filter (where cs.status = 'deferred')::int as deferred_surveys,
  count(*) filter (where cs.status = 'dismissed')::int as dismissed_surveys,
  count(*) filter (where cs.status = 'completed')::int as completed_surveys,
  count(*) filter (where cs.vet_assistance_score is not null)::int as vet_score_count,
  count(*) filter (where cs.app_service_score is not null)::int as app_score_count,
  round(
    100.0 * count(*) filter (where cs.status = 'completed') / greatest(count(*), 1),
    2
  ) as completed_percent
from public.consult_surveys cs
where coalesce(cs.completed_at, cs.updated_at, cs.created_at) >= now() - interval '24 hours'
group by date_trunc('hour', coalesce(cs.completed_at, cs.updated_at, cs.created_at));

create or replace view public.consult_survey_scores_rolling_30d
with (security_invoker = true) as
select
  date_trunc('day', cs.completed_at)::date as day,
  cs.vet_id,
  vu.full_name as vet_name,
  count(*)::int as completed_surveys,
  round(avg(cs.vet_assistance_score)::numeric, 2) as avg_vet_assistance_score,
  round(avg(cs.app_service_score)::numeric, 2) as avg_app_service_score,
  count(*) filter (where nullif(btrim(coalesce(cs.open_feedback, '')), '') is not null)::int as open_feedback_count,
  min(cs.completed_at) as first_completed_at,
  max(cs.completed_at) as last_completed_at
from public.consult_surveys cs
left join public.users vu on vu.id = cs.vet_id
where cs.status = 'completed'
  and cs.completed_at >= now() - interval '30 days'
group by date_trunc('day', cs.completed_at)::date, cs.vet_id, vu.full_name;

comment on view public.consult_survey_pending_observability is 'Pending/deferred consult survey prompts with due state and session context.';
comment on view public.consult_survey_completion_health_24h is 'Hourly 24-hour consult survey completion funnel health.';
comment on view public.consult_survey_scores_rolling_30d is 'Rolling 30-day consult survey score aggregates. App score is aggregate-only for vet-facing use.';

commit;