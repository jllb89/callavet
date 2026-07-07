#!/usr/bin/env zsh
set -euo pipefail

: ${GATEWAY_BASE:?'Set GATEWAY_BASE, e.g. https://cav-gateway-staging-ugvx.onrender.com'}
admin_secret=${ADMIN_SECRET:-${ADMIN_PRICING_SYNC_SECRET:-}}
: ${admin_secret:?'Set ADMIN_SECRET or ADMIN_PRICING_SYNC_SECRET'}

JQ=${JQ:-jq}
if ! command -v "$JQ" >/dev/null 2>&1; then
  print -- 'ERROR: jq is required'
  exit 1
fi

pass=0
fail=0

assert_ok() {
  if [[ $1 -eq 0 ]]; then
    pass=$((pass + 1))
    print -- "PASS: $2"
  else
    fail=$((fail + 1))
    print -- "FAIL: $2"
  fi
}

is_2xx() {
  local code=$1
  [[ "$code" -ge 200 && "$code" -lt 300 ]]
}

admin_get_json() {
  local endpoint=$1
  local output=$2
  local code_output=$3
  local http_code
  http_code=$(curl -sS -o "$output" -w '%{http_code}' -X GET \
    -H "x-admin-secret: $admin_secret" \
    "$GATEWAY_BASE$endpoint")
  print -- "$http_code" > "$code_output"
}

admin_post_json() {
  local endpoint=$1
  local payload=$2
  local output=$3
  local code_output=$4
  local http_code
  http_code=$(curl -sS -o "$output" -w '%{http_code}' -X POST \
    -H "x-admin-secret: $admin_secret" \
    -H 'Content-Type: application/json' \
    --data "$payload" \
    "$GATEWAY_BASE$endpoint")
  print -- "$http_code" > "$code_output"
}

media_ops_tmp=$(mktemp)
media_ops_code_tmp=$(mktemp)
admin_get_json /admin/ops/chat-media "$media_ops_tmp" "$media_ops_code_tmp"
media_ops_code=$(cat "$media_ops_code_tmp")
media_ops_ok=$("$JQ" -r '.ok // false' "$media_ops_tmp" 2>/dev/null || print -- false)
processing_table=$("$JQ" -r '.metrics.processingJobsTable // false' "$media_ops_tmp" 2>/dev/null || print -- false)
ffmpeg_path=$("$JQ" -r '.metrics.processing.ffmpegPath // empty' "$media_ops_tmp" 2>/dev/null || print -- '')
scanner_configured=$("$JQ" -r '.metrics.processing.malwareScannerConfigured // false' "$media_ops_tmp" 2>/dev/null || print -- false)
assert_ok $(is_2xx "$media_ops_code" && [[ "$media_ops_ok" == 'true' ]] && echo 0 || echo 1) 'admin chat media metrics endpoint responds'
assert_ok $([[ "$processing_table" == 'true' ]] && echo 0 || echo 1) 'chat media processing jobs table is migrated'
assert_ok $([[ -n "$ffmpeg_path" ]] && echo 0 || echo 1) 'chat media processing exposes ffmpeg configuration'
assert_ok $([[ "$scanner_configured" == 'true' ]] && echo 0 || echo 1) 'chat media malware scanner is configured'

dry_run_tmp=$(mktemp)
dry_run_code_tmp=$(mktemp)
admin_post_json /admin/ops/chat-media/process '{"dryRun":true,"limit":10}' "$dry_run_tmp" "$dry_run_code_tmp"
dry_run_code=$(cat "$dry_run_code_tmp")
dry_run_ok=$("$JQ" -r '.ok // false' "$dry_run_tmp" 2>/dev/null || print -- false)
dry_run_flag=$("$JQ" -r '.dryRun // false' "$dry_run_tmp" 2>/dev/null || print -- false)
table_ready=$("$JQ" -r '.tableReady // false' "$dry_run_tmp" 2>/dev/null || print -- false)
assert_ok $(is_2xx "$dry_run_code" && [[ "$dry_run_ok" == 'true' && "$dry_run_flag" == 'true' ]] && echo 0 || echo 1) 'media processing dry-run endpoint responds'
assert_ok $([[ "$table_ready" == 'true' ]] && echo 0 || echo 1) 'media processing worker sees jobs table'

run_tmp=$(mktemp)
run_code_tmp=$(mktemp)
admin_post_json /admin/ops/chat-media/process '{"dryRun":false,"limit":5}' "$run_tmp" "$run_code_tmp"
run_code=$(cat "$run_code_tmp")
run_ok=$("$JQ" -r '.ok // false' "$run_tmp" 2>/dev/null || print -- false)
processed=$("$JQ" -r '.processed // 0' "$run_tmp" 2>/dev/null || print -- 0)
assert_ok $(is_2xx "$run_code" && [[ "$run_ok" == 'true' ]] && echo 0 || echo 1) 'media processing worker trigger responds'
print -- "INFO: media processing jobs processed=$processed"

reliability_tmp=$(mktemp)
reliability_code_tmp=$(mktemp)
admin_get_json /admin/ops/chat-reliability "$reliability_tmp" "$reliability_code_tmp"
reliability_code=$(cat "$reliability_code_tmp")
reliability_ok=$("$JQ" -r '.ok // false' "$reliability_tmp" 2>/dev/null || print -- false)
has_playback_rate=$("$JQ" -r 'has("metrics") and (.metrics | has("playbackRefreshFailureRate24h"))' "$reliability_tmp" 2>/dev/null || print -- false)
has_vet_response=$("$JQ" -r 'has("metrics") and (.metrics | has("p95FirstVetResponseMs"))' "$reliability_tmp" 2>/dev/null || print -- false)
assert_ok $(is_2xx "$reliability_code" && [[ "$reliability_ok" == 'true' ]] && echo 0 || echo 1) 'admin chat reliability endpoint responds'
assert_ok $([[ "$has_playback_rate" == 'true' && "$has_vet_response" == 'true' ]] && echo 0 || echo 1) 'chat reliability exposes playback and first-response metrics'

print -- "SUMMARY: pass=$pass fail=$fail"
[[ $fail -eq 0 ]]