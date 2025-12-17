#!/usr/bin/env zsh
set -euo pipefail

# Smoke tests for Appointments module
# Requires: GATEWAY_BASE (fallback SERVER_URL), SB_ACCESS_TOKEN (Supabase access token)
# Optional: VET_ID, SPECIALTY_ID, SINCE, UNTIL, DURATION_MIN

: ${GATEWAY_BASE:=${SERVER_URL:-"http://localhost:3000"}}
: ${SB_ACCESS_TOKEN:=""}
: ${VET_ID:=""}
: ${SPECIALTY_ID:=""}
: ${SINCE:=""}
: ${UNTIL:=""}
: ${DURATION_MIN:=30}

if [[ -z "$SB_ACCESS_TOKEN" ]]; then
  echo "ERROR: SB_ACCESS_TOKEN is required (Supabase bearer)." >&2
  exit 1
fi

hdrs=(-H "Authorization: Bearer $SB_ACCESS_TOKEN" -H "Content-Type: application/json")

jqok='select(.ok // true)'

# 1) List appointments
echo "[1] GET /appointments"
curl -sS "$GATEWAY_BASE/appointments?limit=10&offset=0" $hdrs | tee /dev/stderr | jq '.data | length' | awk '{print "count:", $1}'

# 2) Slots for a vet (requires VET_ID)
if [[ -n "$VET_ID" ]]; then
  qs="durationMin=$DURATION_MIN"
  [[ -n "$SINCE" ]] && qs+="&since=$SINCE"
  [[ -n "$UNTIL" ]] && qs+="&until=$UNTIL"
  echo "[2] GET /vets/$VET_ID/availability/slots?$qs"
  curl -sS "$GATEWAY_BASE/vets/$VET_ID/availability/slots?$qs" $hdrs | tee /dev/stderr | jq '.data | .[0] // {}'
else
  echo "[2] Skipped slots: set VET_ID to test." >&2
fi

# 3) Create appointment: missing specialty (should fail)
if [[ -n "$VET_ID" ]]; then
  startsAt=$(date -u -v+1H +"%Y-%m-%dT%H:%M:%SZ")
  echo "[3] POST /appointments (missing specialty)"
  body=$(jq -n --arg vetId "$VET_ID" --arg startsAt "$startsAt" --argjson durationMin $DURATION_MIN '{vetId: $vetId, startsAt: $startsAt, durationMin: $durationMin}')
  curl -sS -X POST "$GATEWAY_BASE/appointments" $hdrs -d "$body" | tee /dev/stderr | jq '.reason // .status // .ok'
else
  echo "[3] Skipped create missing specialty: set VET_ID." >&2
fi

# 4) Create appointment: with specialty (should succeed)
created_id=""
if [[ -n "$VET_ID" && -n "$SPECIALTY_ID" ]]; then
  startsAt2=$(date -u -v+2H +"%Y-%m-%dT%H:%M:%SZ")
  echo "[4] POST /appointments (with specialty)"
  body2=$(jq -n --arg vetId "$VET_ID" --arg startsAt "$startsAt2" --argjson durationMin $DURATION_MIN --arg specialtyId "$SPECIALTY_ID" '{vetId: $vetId, startsAt: $startsAt, durationMin: $durationMin, specialtyId: $specialtyId}')
  resp=$(curl -sS -X POST "$GATEWAY_BASE/appointments" $hdrs -d "$body2")
  echo "$resp" | jq '{id, vet_id, starts_at, ends_at, status}'
  created_id=$(echo "$resp" | jq -r '.id')
fi

# 5) Create conflicting appointment (should 409)
if [[ -n "$VET_ID" && -n "$SPECIALTY_ID" ]]; then
  echo "[5] POST /appointments (conflict expected)"
  # same start time as previous
  startsAt2=$(echo "$resp" | jq -r '.starts_at')
  body3=$(jq -n --arg vetId "$VET_ID" --arg startsAt "$startsAt2" --argjson durationMin $DURATION_MIN --arg specialtyId "$SPECIALTY_ID" '{vetId: $vetId, startsAt: $startsAt, durationMin: $durationMin, specialtyId: $specialtyId}')
  curl -sS -X POST "$GATEWAY_BASE/appointments" $hdrs -d "$body3" | tee /dev/stderr | jq '(.reason // .status)'
fi

# 6) Patch status to canceled (if created)
if [[ -n "$created_id" && "$created_id" != "null" ]]; then
  echo "[6] PATCH /appointments/$created_id -> canceled"
  body4='{"status":"canceled"}'
  curl -sS -X PATCH "$GATEWAY_BASE/appointments/$created_id" $hdrs -d "$body4" | jq '{id, status}'
fi

echo "Done."
