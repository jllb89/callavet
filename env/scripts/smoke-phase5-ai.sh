#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$ROOT_DIR/../../.env.staging" ]]; then
  set -a
  source "$ROOT_DIR/../../.env.staging"
  set +a
fi

GATEWAY_BASE="${GATEWAY_BASE:-${SERVER_URL:-}}"
BEARER_TOKEN="${SB_ACCESS_TOKEN:-${TOKEN:-}}"
USER_ID="${USER_ID:-00000000-0000-0000-0000-000000000002}"
JQ="${JQ:-jq}"

base64url() {
  printf '%s' "$1" | base64 | tr -d '\n=' | tr '+/' '-_'
}

if [[ -z "$GATEWAY_BASE" ]]; then
  echo "ERROR: GATEWAY_BASE or SERVER_URL is required." >&2
  exit 1
fi

if ! command -v "$JQ" >/dev/null 2>&1; then
  echo "ERROR: jq is required for Phase 5 AI smoke." >&2
  exit 1
fi

if [[ -z "$BEARER_TOKEN" ]]; then
  uuid_re='^[0-9a-fA-F-]{36}$'
  if [[ ! "$USER_ID" =~ $uuid_re ]]; then
    echo "ERROR: SB_ACCESS_TOKEN, TOKEN, or a valid USER_ID is required for Phase 5 AI smoke." >&2
    exit 1
  fi
  header_segment=$(base64url '{"alg":"none","typ":"JWT"}')
  payload_segment=$(base64url "{\"sub\":\"$USER_ID\",\"role\":\"authenticated\"}")
  BEARER_TOKEN="$header_segment.$payload_segment.dev-smoke"
  echo "[phase5-ai] No bearer token provided; using synthetic staging token for USER_ID=$USER_ID"
fi

JSON_HEADER=(-H "Authorization: Bearer $BEARER_TOKEN" -H "Content-Type: application/json")

pass=0
fail=0
assert_ok() {
  if [[ $1 -eq 0 ]]; then
    pass=$((pass+1))
    echo "PASS: $2"
  else
    fail=$((fail+1))
    echo "FAIL: $2"
  fi
}

resolve_pet() {
  local pet_resp create_pet_resp pet_id
  pet_resp=$(curl -sS -X GET "$GATEWAY_BASE/pets" "${JSON_HEADER[@]}" || true)
  pet_id=$(echo "$pet_resp" | "$JQ" -r '.data[0].id // empty' 2>/dev/null || true)
  if [[ -z "$pet_id" ]]; then
    create_pet_resp=$(curl -sS -X POST "$GATEWAY_BASE/pets" "${JSON_HEADER[@]}" -d '{"name":"Phase 5 AI Smoke Horse","species":"horse","sex":"gelding","age_range":"adult_6_15","weight_range":"500_600","location":{"country":"MX","state_region":"Jalisco"},"breed":"criollo","primary_activity":"regular_training","discipline":"recreational","training_intensity":"3_4_per_week","terrain":"mixed","observed_last_6_months":["stiffness"],"known_conditions":["none"],"last_vet_check":"3_6_months","vaccines_up_to_date":"yes","deworming_status":"regular"}' || true)
    pet_id=$(echo "$create_pet_resp" | "$JQ" -r '.id // empty' 2>/dev/null || true)
  fi
  printf '%s' "$pet_id"
}

PET_ID="${PET_ID:-$(resolve_pet)}"
if [[ -z "$PET_ID" ]]; then
  echo "ERROR: Unable to resolve PET_ID for Phase 5 AI smoke." >&2
  exit 1
fi

echo "[phase5-ai] Using PET_ID=$PET_ID"

triage_payload='{"petId":"'$PET_ID'","symptoms":"intermittent stiffness after work, no fever reported","question":"What specialty and priority should be considered?","dryRun":true}'
triage_resp=$(curl -sS -X POST "$GATEWAY_BASE/ai/triage" "${JSON_HEADER[@]}" -d "$triage_payload" || true)
echo "$triage_resp" | "$JQ" . 2>/dev/null || echo "$triage_resp"

echo "$triage_resp" | "$JQ" -e '.ok == true and .draft.draft_type == "triage" and (.eventId | type == "string")' >/dev/null 2>&1
assert_ok $? "AI triage dry-run draft"
triage_event_id=$(echo "$triage_resp" | "$JQ" -r '.eventId // empty')

referral_payload='{"petId":"'$PET_ID'","symptoms":"intermittent stiffness after work","dryRun":true}'
referral_resp=$(curl -sS -X POST "$GATEWAY_BASE/ai/referrals/recommend" "${JSON_HEADER[@]}" -d "$referral_payload" || true)
echo "$referral_resp" | "$JQ" -e '.ok == true and .draft.draft_type == "referral" and (.payload.priority == "routine" or .payload.priority == "urgent")' >/dev/null 2>&1
assert_ok $? "AI referral recommendation dry-run"

note_payload='{"petId":"'$PET_ID'","symptoms":"owner reports mild stiffness","dryRun":true}'
note_resp=$(curl -sS -X POST "$GATEWAY_BASE/ai/drafts/consultation-note" "${JSON_HEADER[@]}" -d "$note_payload" || true)
echo "$note_resp" | "$JQ" -e '.ok == true and .draft.draft_type == "note" and (.payload.summaryText | type == "string")' >/dev/null 2>&1
assert_ok $? "AI consultation note dry-run draft"

care_plan_payload='{"petId":"'$PET_ID'","symptoms":"needs conservative activity plan","dryRun":true}'
care_plan_resp=$(curl -sS -X POST "$GATEWAY_BASE/ai/drafts/care-plan" "${JSON_HEADER[@]}" -d "$care_plan_payload" || true)
echo "$care_plan_resp" | "$JQ" -e '.ok == true and .draft.draft_type == "care_plan" and (.payload.items | type == "array")' >/dev/null 2>&1
assert_ok $? "AI care-plan dry-run draft"

embedding_payload='{"target":"pets","ids":["'$PET_ID'"],"dryRun":true,"persist":false,"limit":1}'
embedding_resp=$(curl -sS -X POST "$GATEWAY_BASE/ai/embeddings/generate" "${JSON_HEADER[@]}" -d "$embedding_payload" || true)
echo "$embedding_resp" | "$JQ" -e '.ok == true and .target == "pets" and .dryRun == true and .persisted == false and (.eventId | type == "string")' >/dev/null 2>&1
assert_ok $? "AI embedding generation dry-run"

drafts_resp=$(curl -sS -X GET "$GATEWAY_BASE/ai/drafts?petId=$PET_ID&limit=10" "${JSON_HEADER[@]}" || true)
echo "$drafts_resp" | "$JQ" -e '.data | type == "array" and length >= 4' >/dev/null 2>&1
assert_ok $? "AI draft listing includes dry-run drafts"

events_resp=$(curl -sS -X GET "$GATEWAY_BASE/ai/events?petId=$PET_ID&status=succeeded&limit=10" "${JSON_HEADER[@]}" || true)
echo "$events_resp" | "$JQ" -e --arg event_id "$triage_event_id" '.data | type == "array" and any(.id == $event_id)' >/dev/null 2>&1
assert_ok $? "AI event audit listing includes triage run"

echo "Summary: PASS=$pass FAIL=$fail"
exit $([[ $fail -eq 0 ]] && echo 0 || echo 1)
