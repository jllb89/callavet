begin;

create or replace view public.ai_chat_formatting_events
with (security_invoker = true) as
select
  e.id,
  e.created_at,
  e.actor_user_id,
  e.provider,
  e.model,
  e.status,
  e.latency_ms,
  nullif(e.response_payload #>> '{formatting,formatVersion}', '')::int as format_version,
  coalesce((nullif(e.response_payload #>> '{formatting,hasDisplayBlocks}', ''))::boolean, false) as has_display_blocks,
  nullif(e.response_payload #>> '{formatting,blockCount}', '')::int as block_count,
  coalesce(e.response_payload #> '{formatting,blockTypes}', '[]'::jsonb) as block_types,
  nullif(e.response_payload #>> '{formatting,listItemCount}', '')::int as list_item_count,
  nullif(e.response_payload #>> '{formatting,messageLength}', '')::int as message_length,
  coalesce((nullif(e.response_payload #>> '{formatting,formattingRepaired}', ''))::boolean, false) as formatting_repaired,
  coalesce(e.response_payload #> '{formatting,formattingWarnings}', '[]'::jsonb) as formatting_warnings,
  coalesce(e.response_payload #> '{payload,displayBlocks}', '[]'::jsonb) as display_blocks,
  left(coalesce(e.response_payload #>> '{payload,message}', ''), 400) as message_preview
from public.ai_events e
where e.event_type = 'ai.chat_turn.run';

create or replace view public.ai_chat_formatting_warning_counts_24h
with (security_invoker = true) as
select
  warning_rows.warning,
  count(*)::int as occurrences
from public.ai_events e
cross join lateral jsonb_array_elements_text(
  coalesce(e.response_payload #> '{formatting,formattingWarnings}', '[]'::jsonb)
) as warning_rows(warning)
where e.event_type = 'ai.chat_turn.run'
  and e.created_at >= now() - interval '24 hours'
group by warning_rows.warning;

create or replace view public.ai_chat_formatting_hourly_health_24h
with (security_invoker = true) as
select
  date_trunc('hour', e.created_at) as hour,
  count(*)::int as total_turns,
  count(*) filter (
    where coalesce((nullif(e.response_payload #>> '{formatting,hasDisplayBlocks}', ''))::boolean, false)
  )::int as turns_with_display_blocks,
  count(*) filter (
    where coalesce((nullif(e.response_payload #>> '{formatting,formattingRepaired}', ''))::boolean, false)
  )::int as repaired_turns,
  round(
    100.0 * count(*) filter (
      where coalesce((nullif(e.response_payload #>> '{formatting,formattingRepaired}', ''))::boolean, false)
    ) / greatest(count(*), 1),
    2
  ) as repaired_percent
from public.ai_events e
where e.event_type = 'ai.chat_turn.run'
  and e.created_at >= now() - interval '24 hours'
group by date_trunc('hour', e.created_at);

comment on view public.ai_chat_formatting_events is 'AI chat turn formatting observability rows derived from ai_events.response_payload.formatting.';
comment on view public.ai_chat_formatting_warning_counts_24h is '24-hour warning counts for AI chat formatting repair metadata.';
comment on view public.ai_chat_formatting_hourly_health_24h is 'Hourly 24-hour AI chat formatting health metrics.';

commit;