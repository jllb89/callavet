#!/usr/bin/env zsh
set -euo pipefail

: ${GATEWAY_BASE:?'Set GATEWAY_BASE, e.g. https://cav-gateway-staging-ugvx.onrender.com'}
: ${OWNER_TOKEN:?'Set OWNER_TOKEN for the horse owner account'}
: ${VET_TOKEN:?'Set VET_TOKEN for the assigned vet account'}
: ${PET_ID:?'Set PET_ID owned by OWNER_TOKEN'}
: ${VET_ID:?'Set VET_ID for the assigned vet'}
: ${SPECIALTY_ID:?'Set SPECIALTY_ID covered by VET_ID'}

JQ=${JQ:-jq}
if ! command -v "$JQ" >/dev/null 2>&1; then
  print -- 'ERROR: jq is required'
  exit 1
fi

owner_hdr=(-H "Authorization: Bearer $OWNER_TOKEN" -H 'Content-Type: application/json')
vet_hdr=(-H "Authorization: Bearer $VET_TOKEN" -H 'Content-Type: application/json')
admin_secret=${ADMIN_SECRET:-${ADMIN_PRICING_SYNC_SECRET:-}}
pass=0
fail=0
created_session=''

assert_ok() {
  if [[ $1 -eq 0 ]]; then
    pass=$((pass + 1))
    print -- "PASS: $2"
  else
    fail=$((fail + 1))
    print -- "FAIL: $2"
  fi
}

post_json() {
  local token_kind=$1
  local endpoint=$2
  local payload=$3
  local output=$4
  local code_output=$5
  local -a hdr
  if [[ "$token_kind" == 'vet' ]]; then
    hdr=($vet_hdr[@])
  else
    hdr=($owner_hdr[@])
  fi
  local http_code
  http_code=$(curl -sS -o "$output" -w '%{http_code}' -X POST $hdr[@] --data "$payload" "$GATEWAY_BASE$endpoint")
  print -- "$http_code" > "$code_output"
}

get_json() {
  local token_kind=$1
  local endpoint=$2
  local output=$3
  local code_output=$4
  local -a hdr
  if [[ "$token_kind" == 'vet' ]]; then
    hdr=($vet_hdr[@])
  else
    hdr=($owner_hdr[@])
  fi
  local http_code
  http_code=$(curl -sS -o "$output" -w '%{http_code}' -X GET $hdr[@] "$GATEWAY_BASE$endpoint")
  print -- "$http_code" > "$code_output"
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

is_2xx() {
  local code=$1
  [[ "$code" -ge 200 && "$code" -lt 300 ]]
}

cleanup_session() {
  if [[ -z "$created_session" ]]; then return; fi
  curl -sS -X POST $vet_hdr[@] --data '{}' "$GATEWAY_BASE/vets/me/consults/$created_session/end" >/dev/null || true
}
trap cleanup_session EXIT

start_body=$("$JQ" -n \
  --arg petId "$PET_ID" \
  --arg vetId "$VET_ID" \
  --arg specialtyId "$SPECIALTY_ID" \
  '{
    kind: "chat",
    petId: $petId,
    vetId: $vetId,
    specialtyId: $specialtyId,
    priority: "medium",
    aiContext: {
      source: "chat_consult_realtime_smoke",
      assistantPayload: {
        urgency: "medium",
        recommendedService: "chat",
        caseSummary: "Smoke test case summary generated for launch validation.",
        handoffSummary: "Smoke test handoff summary generated for launch validation."
      },
      messages: [
        { role: "user", content: "Smoke test owner message before handoff." },
        { role: "assistant", content: "Smoke test AI handoff prepared for veterinarian." }
      ],
      routing: {
        vetId: $vetId,
        specialtyId: $specialtyId,
        recommendedService: "chat"
      }
    }
  }')

start_tmp=$(mktemp)
start_code_tmp=$(mktemp)
post_json owner /sessions/start "$start_body" "$start_tmp" "$start_code_tmp"
start_code=$(cat "$start_code_tmp")
session_id=$("$JQ" -r '.sessionId // empty' "$start_tmp" 2>/dev/null || true)
overage=$("$JQ" -r '.overage // false' "$start_tmp" 2>/dev/null || print -- false)
consumption_committed=$("$JQ" -r '.consumptionCommitted // false' "$start_tmp" 2>/dev/null || print -- false)
assert_ok $(is_2xx "$start_code" && [[ -n "$session_id" && "$overage" != 'true' ]] && echo 0 || echo 1) 'owner starts assigned chat consult'
if [[ -z "$session_id" || "$overage" == 'true' ]]; then
  print -- "start status=$start_code body=$(cat "$start_tmp")"
  exit 1
fi
assert_ok $([[ "$consumption_committed" == 'true' ]] && echo 0 || echo 1) 'chat consumption is committed on start'
created_session="$session_id"
print -- "[chat-realtime] Session under test: $session_id"

handoff_tmp=$(mktemp)
handoff_code_tmp=$(mktemp)
get_json vet "/sessions/$session_id/handoff" "$handoff_tmp" "$handoff_code_tmp"
handoff_code=$(cat "$handoff_code_tmp")
assert_ok $(is_2xx "$handoff_code" && echo 0 || echo 1) 'assigned vet can load AI handoff'

owner_key="owner-smoke-$(date +%s)"
owner_payload=$("$JQ" -n --arg content 'Owner realtime smoke message' --arg clientKey "$owner_key" '{content:$content, clientKey:$clientKey}')
owner_msg_tmp=$(mktemp)
owner_msg_code_tmp=$(mktemp)
post_json owner "/sessions/$session_id/messages" "$owner_payload" "$owner_msg_tmp" "$owner_msg_code_tmp"
owner_msg_code=$(cat "$owner_msg_code_tmp")
owner_stream=$("$JQ" -r '.message.stream_order // 0' "$owner_msg_tmp" 2>/dev/null || print -- 0)
assert_ok $(is_2xx "$owner_msg_code" && [[ "$owner_stream" -gt 0 ]] && echo 0 || echo 1) 'owner sends message with stream_order'

owner_dup_tmp=$(mktemp)
owner_dup_code_tmp=$(mktemp)
post_json owner "/sessions/$session_id/messages" "$owner_payload" "$owner_dup_tmp" "$owner_dup_code_tmp"
owner_dup_code=$(cat "$owner_dup_code_tmp")
owner_duplicate=$("$JQ" -r '.duplicate // false' "$owner_dup_tmp" 2>/dev/null || print -- false)
assert_ok $(is_2xx "$owner_dup_code" && [[ "$owner_duplicate" == 'true' ]] && echo 0 || echo 1) 'duplicate owner clientKey is idempotent'

vet_list_tmp=$(mktemp)
vet_list_code_tmp=$(mktemp)
get_json vet "/sessions/$session_id/messages?limit=100&sort=stream_order.asc" "$vet_list_tmp" "$vet_list_code_tmp"
vet_list_code=$(cat "$vet_list_code_tmp")
vet_sees_owner=$("$JQ" -r --argjson stream "$owner_stream" '[.items[]? | select(.stream_order == $stream and .role == "user")] | length' "$vet_list_tmp" 2>/dev/null || print -- 0)
assert_ok $(is_2xx "$vet_list_code" && [[ "$vet_sees_owner" -ge 1 ]] && echo 0 || echo 1) 'vet sync sees owner message under RLS'

vet_read_tmp=$(mktemp)
vet_read_code_tmp=$(mktemp)
post_json vet "/sessions/$session_id/messages/read" '{"lastStreamOrder":'"$owner_stream"'}' "$vet_read_tmp" "$vet_read_code_tmp"
vet_read_code=$(cat "$vet_read_code_tmp")
vet_marked=$("$JQ" -r '.marked // 0' "$vet_read_tmp" 2>/dev/null || print -- 0)
assert_ok $(is_2xx "$vet_read_code" && [[ "$vet_marked" -ge 1 ]] && echo 0 || echo 1) 'vet marks owner message read'

vet_key="vet-smoke-$(date +%s)"
vet_payload=$("$JQ" -n --arg content 'Vet realtime smoke response' --arg clientKey "$vet_key" '{content:$content, clientKey:$clientKey}')
vet_msg_tmp=$(mktemp)
vet_msg_code_tmp=$(mktemp)
post_json vet "/sessions/$session_id/messages" "$vet_payload" "$vet_msg_tmp" "$vet_msg_code_tmp"
vet_msg_code=$(cat "$vet_msg_code_tmp")
vet_stream=$("$JQ" -r '.message.stream_order // 0' "$vet_msg_tmp" 2>/dev/null || print -- 0)
assert_ok $(is_2xx "$vet_msg_code" && [[ "$vet_stream" -gt "$owner_stream" ]] && echo 0 || echo 1) 'vet sends response with stream_order'

owner_delta_tmp=$(mktemp)
owner_delta_code_tmp=$(mktemp)
get_json owner "/sessions/$session_id/messages?afterStreamOrder=$owner_stream&limit=20&sort=stream_order.asc" "$owner_delta_tmp" "$owner_delta_code_tmp"
owner_delta_code=$(cat "$owner_delta_code_tmp")
owner_sees_vet=$("$JQ" -r --argjson stream "$vet_stream" '[.items[]? | select(.stream_order == $stream and .role == "vet")] | length' "$owner_delta_tmp" 2>/dev/null || print -- 0)
assert_ok $(is_2xx "$owner_delta_code" && [[ "$owner_sees_vet" -ge 1 ]] && echo 0 || echo 1) 'owner cursor sync sees vet response'

owner_read_tmp=$(mktemp)
owner_read_code_tmp=$(mktemp)
post_json owner "/sessions/$session_id/messages/read" '{"lastStreamOrder":'"$vet_stream"'}' "$owner_read_tmp" "$owner_read_code_tmp"
owner_read_code=$(cat "$owner_read_code_tmp")
owner_marked=$("$JQ" -r '.marked // 0' "$owner_read_tmp" 2>/dev/null || print -- 0)
assert_ok $(is_2xx "$owner_read_code" && [[ "$owner_marked" -ge 1 ]] && echo 0 || echo 1) 'owner marks vet response read'

end_tmp=$(mktemp)
end_code_tmp=$(mktemp)
post_json owner "/sessions/end" '{"sessionId":"'$session_id'"}' "$end_tmp" "$end_code_tmp"
end_code=$(cat "$end_code_tmp")
ended=$("$JQ" -r '.ended // false' "$end_tmp" 2>/dev/null || print -- false)
assert_ok $(is_2xx "$end_code" && [[ "$ended" == 'true' ]] && echo 0 || echo 1) 'owner ends chat consult'
created_session=''

survey_tmp=$(mktemp)
survey_code_tmp=$(mktemp)
get_json owner "/sessions/$session_id/survey" "$survey_tmp" "$survey_code_tmp"
survey_code=$(cat "$survey_code_tmp")
survey_eligible=$("$JQ" -r '.eligible // false' "$survey_tmp" 2>/dev/null || print -- false)
assert_ok $(is_2xx "$survey_code" && [[ "$survey_eligible" == 'true' ]] && echo 0 || echo 1) 'owner survey is eligible after completed chat'

if [[ -n "$admin_secret" ]]; then
  ops_tmp=$(mktemp)
  ops_code_tmp=$(mktemp)
  admin_get_json /admin/ops/chat-consultations "$ops_tmp" "$ops_code_tmp"
  ops_code=$(cat "$ops_code_tmp")
  ops_ok=$("$JQ" -r '.ok // false' "$ops_tmp" 2>/dev/null || print -- false)
  assert_ok $(is_2xx "$ops_code" && [[ "$ops_ok" == 'true' ]] && echo 0 || echo 1) 'admin chat consultation metrics endpoint'
else
  print -- 'SKIP: admin chat consultation metrics endpoint (set ADMIN_SECRET or ADMIN_PRICING_SYNC_SECRET)'
fi

print -- "SUMMARY: pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
