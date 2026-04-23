#!/usr/bin/env bash
set -euo pipefail

BASE="${GATEWAY_BASE:-${SERVER_URL:-}}"
AUTH_HEADER=${AUTH_HEADER:-"Authorization: Bearer ${SB_ACCESS_TOKEN:-}"}
JQ=${JQ:-jq}

pass=0
fail=0
assert_ok() { if [[ $1 -eq 0 ]]; then pass=$((pass+1)); echo "PASS: $2"; else fail=$((fail+1)); echo "FAIL: $2"; fi; }

if [[ -z "$BASE" ]]; then
  echo "ERROR: set GATEWAY_BASE or SERVER_URL"
  exit 1
fi

pet_id="${PET_ID:-}"
if [[ -z "$pet_id" ]]; then
  pet_id=$(curl -sS -H "$AUTH_HEADER" "$BASE/pets" | $JQ -r '.data[0].id // empty')
fi
if [[ -z "$pet_id" ]]; then
  echo "ERROR: PET_ID not found"
  exit 1
fi

# 1) Upsert structured health profile
profile_payload='{
  "allergies": ["pollen"],
  "chronic_conditions": ["mild_lameness"],
  "current_medications": [{"name":"supplement_a","dose":"10ml"}],
  "vaccine_history": [{"name":"influenza","date":"2026-01-15"}],
  "injury_history": [{"type":"tendon_strain","date":"2025-10-04"}],
  "procedure_history": [{"type":"dental_float","date":"2025-08-10"}],
  "feed_profile": {"hay":"alfalfa","supplements":["omega3"]},
  "insurance": {"provider":"demo-insure","policy":"HX-001"},
  "emergency_contacts": [{"name":"Barn Manager","phone":"+525500000000"}]
}'

resp=$(curl -sS -X PUT -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  -d "$profile_payload" \
  "$BASE/pets/$pet_id/health-profile") || true

echo "$resp" | $JQ -e '.pet_id == "'$pet_id'" and (.allergies | index("pollen") != null)' >/dev/null 2>&1
assert_ok $? "health profile upsert"

# 2) Read back profile
resp=$(curl -sS -H "$AUTH_HEADER" "$BASE/pets/$pet_id/health-profile") || true
echo "$resp" | $JQ -e '(.current_medications | type == "array") and (.feed_profile | type == "object")' >/dev/null 2>&1
assert_ok $? "health profile get"

# 3) Create session + structured note
session_id=$(curl -sS -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  -d '{"kind":"chat"}' "$BASE/sessions/start" | $JQ -r '.sessionId // empty')
[[ -n "$session_id" ]]
assert_ok $? "session start for clinical record"

note_payload='{
  "summary_text": "Horse shows intermittent stiffness.",
  "plan_summary": "Continue light work and monitor progression.",
  "assessment_text": "Mild stiffness on left hind observed after warm-up.",
  "diagnosis_text": "Probable mild soft tissue strain.",
  "follow_up_instructions": "Recheck in 10 days or sooner if worsens.",
  "severity": "medium",
  "pet_id": "'$pet_id'"
}'

note_resp=$(curl -sS -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  -d "$note_payload" "$BASE/sessions/$session_id/notes") || true
encounter_id=$(echo "$note_resp" | $JQ -r '.encounter_id // empty')

echo "$note_resp" | $JQ -e '.assessment_text != null and .diagnosis_text != null and .severity == "medium"' >/dev/null 2>&1
assert_ok $? "structured session note create"
[[ -n "$encounter_id" ]]
assert_ok $? "encounter id from structured note"

# 4) Create care plan linked to same session/encounter
plan_resp=$(curl -sS -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  -d '{"session_id":"'$session_id'","encounter_id":"'$encounter_id'","created_by_ai":false,"short_term":"7 days rest","mid_term":"resume trot","long_term":"full training"}' \
  "$BASE/pets/$pet_id/care-plans") || true

echo "$plan_resp" | $JQ -e '.encounter_id == "'$encounter_id'"' >/dev/null 2>&1
assert_ok $? "care plan linked to encounter"

# 5) Upload file artifact linked to encounter
upload_path="pets/$pet_id/encounters/$encounter_id/smoke-phase4.txt"
content_b64=$(printf 'phase4-clinical-record-smoke' | base64 | tr -d '\n')
file_resp=$(curl -sS -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  -d '{"path":"'$upload_path'","content":"'$content_b64'","contentType":"text/plain","petId":"'$pet_id'","sessionId":"'$session_id'","encounterId":"'$encounter_id'","labels":["phase4-smoke"]}' \
  "$BASE/files/upload") || true

echo "$file_resp" | $JQ -e '.ok == true' >/dev/null 2>&1
assert_ok $? "encounter file upload"

# 6) Encounter timeline list + detail
list_resp=$(curl -sS -H "$AUTH_HEADER" "$BASE/pets/$pet_id/encounters?limit=10") || true

echo "$list_resp" | $JQ -e '.data | type == "array"' >/dev/null 2>&1
assert_ok $? "encounter list"

echo "$list_resp" | $JQ -e '.data | map(select(.id == "'$encounter_id'")) | length >= 1' >/dev/null 2>&1
assert_ok $? "encounter list contains created encounter"

detail_resp=$(curl -sS -H "$AUTH_HEADER" "$BASE/encounters/$encounter_id") || true

echo "$detail_resp" | $JQ -e '.encounter.id == "'$encounter_id'" and (.notes | length >= 1) and (.carePlans | length >= 1) and (.files | length >= 1)' >/dev/null 2>&1
assert_ok $? "encounter detail timeline aggregation"

echo "$detail_resp" | $JQ -e '.healthProfile.pet_id == "'$pet_id'"' >/dev/null 2>&1
assert_ok $? "encounter detail includes health profile"

echo "Summary: PASS=$pass FAIL=$fail"
exit $([[ $fail -eq 0 ]] && echo 0 || echo 1)
