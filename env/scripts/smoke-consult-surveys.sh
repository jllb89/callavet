#!/usr/bin/env zsh
set -euo pipefail

: ${GATEWAY_BASE:?'Set GATEWAY_BASE, e.g. https://cav-gateway-staging-ugvx.onrender.com'}
: ${OWNER_TOKEN:?'Set OWNER_TOKEN for the session owner account'}
: ${SESSION_ID:?'Set SESSION_ID for an eligible completed/ended consult'}

JQ=${JQ:-jq}
if ! command -v "$JQ" >/dev/null 2>&1; then
  print -- 'ERROR: jq is required'
  exit 1
fi

hdr=(-H "Authorization: Bearer $OWNER_TOKEN" -H 'Content-Type: application/json')
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

request_json() {
  local method=$1
  local endpoint=$2
  local payload=$3
  local output=$4
  local status_output=$5
  local -a args
  args=(-sS -o "$output" -w '%{http_code}' -X "$method" $hdr[@])
  if [[ -n "$payload" ]]; then
    args+=(--data "$payload")
  fi
  local http_status
  http_status=$(curl $args[@] "$GATEWAY_BASE$endpoint")
  print -- "$http_status" > "$status_output"
}

print -- "[consult-survey] Session under test: $SESSION_ID"

survey_tmp=$(mktemp)
survey_status=$(mktemp)
request_json GET "/sessions/$SESSION_ID/survey" '' "$survey_tmp" "$survey_status"
survey_id=$("$JQ" -r '.survey.id // empty' "$survey_tmp" 2>/dev/null || true)
eligible=$("$JQ" -r '.eligible // false' "$survey_tmp" 2>/dev/null || true)
assert_ok $([[ -n "$survey_id" && "$eligible" == 'true' && "$(cat "$survey_status")" -ge 200 && "$(cat "$survey_status")" -lt 300 ]] && echo 0 || echo 1) 'get/create survey candidate'

prompt_tmp=$(mktemp)
prompt_status=$(mktemp)
request_json POST "/sessions/$SESSION_ID/survey/prompt-response" '{"answer":"now"}' "$prompt_tmp" "$prompt_status"
prompt_state=$("$JQ" -r '.survey.status // empty' "$prompt_tmp" 2>/dev/null || true)
assert_ok $([[ "$prompt_state" == 'accepted' ]] && echo 0 || echo 1) 'accept survey prompt now'

patch_tmp=$(mktemp)
patch_status=$(mktemp)
request_json PATCH "/sessions/$SESSION_ID/survey" '{"vetAssistanceScore":5,"appServiceScore":4}' "$patch_tmp" "$patch_status"
vet_score=$("$JQ" -r '.survey.vetAssistanceScore // empty' "$patch_tmp" 2>/dev/null || true)
app_score=$("$JQ" -r '.survey.appServiceScore // empty' "$patch_tmp" 2>/dev/null || true)
assert_ok $([[ "$vet_score" == '5' && "$app_score" == '4' ]] && echo 0 || echo 1) 'save vet and app scores'

complete_tmp=$(mktemp)
complete_status=$(mktemp)
request_json PATCH "/sessions/$SESSION_ID/survey" '{"status":"completed","openFeedback":"Smoke survey feedback"}' "$complete_tmp" "$complete_status"
complete_state=$("$JQ" -r '.survey.status // empty' "$complete_tmp" 2>/dev/null || true)
rating_score=$("$JQ" -r '.rating.score // empty' "$complete_tmp" 2>/dev/null || true)
assert_ok $([[ "$complete_state" == 'completed' && "$rating_score" == '5' ]] && echo 0 || echo 1) 'complete survey and upsert vet rating score only'

pending_tmp=$(mktemp)
pending_status=$(mktemp)
request_json GET /me/surveys/pending '' "$pending_tmp" "$pending_status"
pending_count=$("$JQ" -r '.data | length' "$pending_tmp" 2>/dev/null || print -- 0)
assert_ok $([[ "$(cat "$pending_status")" -ge 200 && "$(cat "$pending_status")" -lt 300 ]] && echo 0 || echo 1) 'pending survey endpoint reachable'
print -- "[consult-survey] Pending surveys currently due: $pending_count"

print -- "Summary: PASS=$pass FAIL=$fail"
exit $([[ $fail -eq 0 ]] && echo 0 || echo 1)