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

pass=0
fail=0
created_sessions=()

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
  local status_output=$5
  local -a hdr
  if [[ "$token_kind" == 'vet' ]]; then
    hdr=($vet_hdr[@])
  else
    hdr=($owner_hdr[@])
  fi
  local http_status
  http_status=$(curl -sS -o "$output" -w '%{http_code}' -X POST $hdr[@] --data "$payload" "$GATEWAY_BASE$endpoint")
  print -- "$http_status" > "$status_output"
}

get_json() {
  local token_kind=$1
  local endpoint=$2
  local output=$3
  local status_output=$4
  local -a hdr
  if [[ "$token_kind" == 'vet' ]]; then
    hdr=($vet_hdr[@])
  else
    hdr=($owner_hdr[@])
  fi
  local http_status
  http_status=$(curl -sS -o "$output" -w '%{http_code}' -X GET $hdr[@] "$GATEWAY_BASE$endpoint")
  print -- "$http_status" > "$status_output"
}

cleanup_sessions() {
  if [[ ${#created_sessions[@]} -eq 0 ]]; then return; fi
  for session_id in $created_sessions; do
    curl -sS -X POST $owner_hdr[@] --data '{"sessionId":"'$session_id'"}' "$GATEWAY_BASE/sessions/end" >/dev/null || true
  done
}
trap cleanup_sessions EXIT

body='{"kind":"video","petId":"'$PET_ID'","vetId":"'$VET_ID'","specialtyId":"'$SPECIALTY_ID'","priority":"urgent","aiContext":{"source":"phase6_regression","assistantPayload":{"urgency":"urgent","recommendedService":"video","caseSummary":"Phase 6 regression fixture case summary.","handoffSummary":"Phase 6 regression fixture handoff summary."},"messages":[{"role":"user","content":"Phase 6 regression smoke video consult."},{"role":"assistant","content":"Preparing AI handoff for the veterinarian.","metadata":{"nextStep":"recommendation","urgency":"urgent","recommendedService":"video"}}],"routing":{"vetId":"'$VET_ID'","specialtyId":"'$SPECIALTY_ID'","recommendedService":"video"}}}'

tmp1=$(mktemp)
tmp2=$(mktemp)
st1=$(mktemp)
st2=$(mktemp)

print -- '[phase6-video] Starting two concurrent /sessions/start requests for same vet'
post_json owner /sessions/start "$body" "$tmp1" "$st1" &
pid1=$!
post_json owner /sessions/start "$body" "$tmp2" "$st2" &
pid2=$!
wait $pid1 || true
wait $pid2 || true

status1=$(cat "$st1")
status2=$(cat "$st2")
session1=$("$JQ" -r '.sessionId // empty' "$tmp1" 2>/dev/null || true)
session2=$("$JQ" -r '.sessionId // empty' "$tmp2" 2>/dev/null || true)
overage1=$("$JQ" -r '.overage // false' "$tmp1" 2>/dev/null || print -- false)
overage2=$("$JQ" -r '.overage // false' "$tmp2" 2>/dev/null || print -- false)
busy1=$(grep -c 'vet_busy' "$tmp1" || true)
busy2=$(grep -c 'vet_busy' "$tmp2" || true)
success_count=0
busy_count=0
[[ -n "$session1" && "$status1" -ge 200 && "$status1" -lt 300 && "$overage1" != 'true' ]] && success_count=$((success_count + 1))
[[ -n "$session2" && "$status2" -ge 200 && "$status2" -lt 300 && "$overage2" != 'true' ]] && success_count=$((success_count + 1))
[[ "$status1" == '409' || "$busy1" -gt 0 ]] && busy_count=$((busy_count + 1))
[[ "$status2" == '409' || "$busy2" -gt 0 ]] && busy_count=$((busy_count + 1))
assert_ok $([[ "$success_count" -eq 1 && "$busy_count" -eq 1 ]] && echo 0 || echo 1) 'vet busy lock race allows one session and rejects one vet_busy'

session_id="$session1"
[[ "$overage1" == 'true' ]] && session_id=""
[[ -z "$session_id" && "$overage2" != 'true' ]] && session_id="$session2"
if [[ -z "$session_id" ]]; then
  print -- 'ERROR: no non-overage successful session created; cannot continue regression smoke'
  print -- "[phase6-video] first status=$status1 overage=$overage1 body=$(cat "$tmp1")"
  print -- "[phase6-video] second status=$status2 overage=$overage2 body=$(cat "$tmp2")"
  exit 1
fi
created_sessions+=("$session_id")
print -- "[phase6-video] Session under test: $session_id"

handoff_tmp=$(mktemp)
handoff_status=$(mktemp)
get_json vet "/sessions/$session_id/handoff" "$handoff_tmp" "$handoff_status"
handoff_ready=$("$JQ" -r '.ready == true' "$handoff_tmp" 2>/dev/null || print -- false)
assert_ok $([[ "$(cat "$handoff_status")" -ge 200 && "$(cat "$handoff_status")" -lt 300 ]] && echo 0 || echo 1) 'handoff endpoint is reachable to assigned vet'
print -- "[phase6-video] Handoff ready=$handoff_ready"

room_tmp=$(mktemp)
room_status=$(mktemp)
post_json owner /video/rooms '{"sessionId":"'$session_id'","participantRole":"owner"}' "$room_tmp" "$room_status"
room_id=$("$JQ" -r '.roomId // empty' "$room_tmp" 2>/dev/null || true)
assert_ok $([[ -n "$room_id" && "$(cat "$room_status")" -ge 200 && "$(cat "$room_status")" -lt 300 ]] && echo 0 || echo 1) 'owner can create LiveKit room'
if [[ -z "$room_id" ]]; then
  print -- "[phase6-video] room create status=$(cat "$room_status") body=$(cat "$room_tmp")"
fi

end_tmp=$(mktemp)
end_status=$(mktemp)
post_json vet "/video/rooms/$room_id/end" '{"participantRole":"vet","reason":"vet_ended"}' "$end_tmp" "$end_status"
end_reason=$("$JQ" -r '.endState.endReason // empty' "$end_tmp" 2>/dev/null || true)
rejoin=$("$JQ" -r '.endState.rejoinEligible // false' "$end_tmp" 2>/dev/null || true)
assert_ok $([[ "$end_reason" == 'vet_ended' && "$rejoin" == 'true' ]] && echo 0 || echo 1) 'vet end maps to vet_ended with owner rejoin eligibility'

vet_rejoin_tmp=$(mktemp)
vet_rejoin_status=$(mktemp)
post_json vet /video/rooms '{"sessionId":"'$session_id'","participantRole":"vet"}' "$vet_rejoin_tmp" "$vet_rejoin_status"
vet_rejoin_room_id=$("$JQ" -r '.roomId // empty' "$vet_rejoin_tmp" 2>/dev/null || true)
assert_ok $([[ -n "$vet_rejoin_room_id" && "$(cat "$vet_rejoin_status")" -ge 200 && "$(cat "$vet_rejoin_status")" -lt 300 ]] && echo 0 || echo 1) 'vet can rejoin during rejoin window after vet_ended'
if [[ -z "$vet_rejoin_room_id" ]]; then
  print -- "[phase6-video] vet rejoin status=$(cat "$vet_rejoin_status") body=$(cat "$vet_rejoin_tmp")"
fi

post_call_tmp=$(mktemp)
post_call_status=$(mktemp)
post_json owner "/video/sessions/$session_id/post-call-message" '{"endState":{"sessionId":"'$session_id'","endReason":"vet_ended","endedByRole":"vet","rejoinEligible":true,"recommendedAction":"rejoin"}}' "$post_call_tmp" "$post_call_status"
post_call_message=$("$JQ" -r '.payload.message // empty' "$post_call_tmp" 2>/dev/null || true)
assert_ok $([[ -n "$post_call_message" && "$(cat "$post_call_status")" -ge 200 && "$(cat "$post_call_status")" -lt 300 ]] && echo 0 || echo 1) 'post-call AI message endpoint returns message'

if [[ -x ./env/scripts/smoke-video-observability.sh ]]; then
  print -- '[phase6-video] Running observability smoke'
  env/scripts/smoke-video-observability.sh >/tmp/cav-video-observability-smoke.log
  assert_ok $? 'observability smoke succeeds'
fi

print -- "Summary: PASS=$pass FAIL=$fail"
exit $([[ $fail -eq 0 ]] && echo 0 || echo 1)