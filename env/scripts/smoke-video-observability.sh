#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ -f "$ROOT_DIR/env/scripts/export-staging.sh" && -z "${SUPABASE_DIRECT_DATABASE_URL:-}" ]]; then
  source "$ROOT_DIR/env/scripts/export-staging.sh" >/dev/null
fi

: ${SUPABASE_DIRECT_DATABASE_URL:=${DATABASE_URL:-}}
: ${SUPABASE_DIRECT_DATABASE_URL:?"Set SUPABASE_DIRECT_DATABASE_URL or DATABASE_URL"}

views=(
  active_vet_consult_lock_observability
  vet_consult_lock_recent_events
  ai_handoff_session_observability
  ai_handoff_generation_health_24h
  video_lifecycle_observability
  video_lifecycle_health_24h
  recent_video_event_observability
)

print -- "[video-observability] Checking Phase 5 views"

for view in $views; do
  print -- "[video-observability] public.$view"
  psql "$SUPABASE_DIRECT_DATABASE_URL" -v ON_ERROR_STOP=1 -P pager=off -c "select * from public.$view limit 5;"
done

print -- "[video-observability] Summary counts"
psql "$SUPABASE_DIRECT_DATABASE_URL" -v ON_ERROR_STOP=1 -P pager=off -c "
select 'active_locks' as metric, count(*)::text as value from public.active_vet_consult_lock_observability
union all
select 'handoff_missing_or_failed', count(*)::text from public.ai_handoff_session_observability where handoff_state in ('missing', 'failed')
union all
select 'video_lifecycle_attention', count(*)::text from public.video_lifecycle_observability where lifecycle_health_state not in ('normal', 'closed', 'live_or_engaged')
union all
select 'recent_livekit_events', count(*)::text from public.recent_video_event_observability;
"

print -- "[video-observability] Smoke complete"