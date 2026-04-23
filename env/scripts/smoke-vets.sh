#!/usr/bin/env zsh
set -euo pipefail

: ${GATEWAY_BASE:=${SERVER_URL:-"http://localhost:3000"}}
: ${SB_ACCESS_TOKEN:=""}
: ${USER_ID:=""}
: ${PET_ID:=""}
: ${VET_ID:=00000000-0000-0000-0000-000000000003}
: ${VET_USER_ID:=${VET_ID}}
: ${ADMIN_PRICING_SYNC_SECRET:=${ADMIN_SECRET:-""}}

if [[ -z "$SB_ACCESS_TOKEN" ]]; then
  echo "ERROR: SB_ACCESS_TOKEN is required." >&2
  exit 1
fi

if [[ -z "$PET_ID" ]]; then
  echo "ERROR: PET_ID is required." >&2
  exit 1
fi

base64url() {
  printf '%s' "$1" | base64 | tr -d '\n=' | tr '+/' '-_'
}

owner_hdr=(-H "Authorization: Bearer $SB_ACCESS_TOKEN" -H "Content-Type: application/json")
vet_header=$(base64url '{"alg":"none","typ":"JWT"}')
vet_payload=$(base64url "{\"sub\":\"$VET_USER_ID\",\"role\":\"authenticated\"}")
VET_ACCESS_TOKEN="$vet_header.$vet_payload.dev-smoke"
vet_hdr=(-H "Authorization: Bearer $VET_ACCESS_TOKEN" -H "Content-Type: application/json")
admin_hdr=($owner_hdr)
[[ -n "$ADMIN_PRICING_SYNC_SECRET" ]] && admin_hdr+=(-H "x-admin-secret: $ADMIN_PRICING_SYNC_SECRET")

echo "[vets] GET /vets/specialties"
specialties_resp=$(curl -sS "$GATEWAY_BASE/vets/specialties" $owner_hdr)
echo "$specialties_resp" | jq '{count: (.data | length)}'
SPECIALTY_ID=$(echo "$specialties_resp" | jq -r '.data[0].id // empty')
if [[ -z "$SPECIALTY_ID" ]]; then
  echo "ERROR: no specialties available for vet smoke" >&2
  exit 1
fi

echo "[vets] GET /vets"
vets_resp=$(curl -sS "$GATEWAY_BASE/vets?specialtyId=$SPECIALTY_ID" $owner_hdr)
echo "$vets_resp" | jq '{count: (.data | length)}'

if [[ -n "$ADMIN_PRICING_SYNC_SECRET" ]]; then
  echo "[vets] POST /vets/$VET_ID/approve"
  approve_resp=$(curl -sS -X POST "$GATEWAY_BASE/vets/$VET_ID/approve" $admin_hdr)
  echo "$approve_resp" | jq '{id, is_approved}'
fi

echo "[vets] PATCH /vets/me/profile"
profile_body=$(jq -n --arg specialtyId "$SPECIALTY_ID" '{
  bio: "Phase 1 staging vet profile",
  country: "MX",
  years_experience: 8,
  specialties: [$specialtyId],
  languages: ["es", "en"]
}')
profile_resp=$(curl -sS -X PATCH "$GATEWAY_BASE/vets/me/profile" $vet_hdr -d "$profile_body")
echo "$profile_resp" | jq '{id, is_approved, specialties, languages}'

echo "[vets] PUT /vets/me/availability"
availability_body=$(jq -n '{template: [
  {weekday: 0, start_time: "08:00", end_time: "20:00", timezone: "UTC"},
  {weekday: 1, start_time: "08:00", end_time: "20:00", timezone: "UTC"},
  {weekday: 2, start_time: "08:00", end_time: "20:00", timezone: "UTC"},
  {weekday: 3, start_time: "08:00", end_time: "20:00", timezone: "UTC"},
  {weekday: 4, start_time: "08:00", end_time: "20:00", timezone: "UTC"},
  {weekday: 5, start_time: "08:00", end_time: "20:00", timezone: "UTC"},
  {weekday: 6, start_time: "08:00", end_time: "20:00", timezone: "UTC"}
]}')
availability_resp=$(curl -sS -X PUT "$GATEWAY_BASE/vets/me/availability" $vet_hdr -d "$availability_body")
echo "$availability_resp" | jq '{template_count: (.template | length)}'

echo "[vets] GET /vets/me/queue"
queue_before=$(curl -sS "$GATEWAY_BASE/vets/me/queue" $vet_hdr)
echo "$queue_before" | jq '{upcoming: (.upcomingAppointments | length), active: (.activeConsults | length), pendingNotes: (.pendingNotes | length), referrals: (.referrals | length)}'

echo "[vets] POST /vets/referrals"
referral_body=$(jq -n --arg petId "$PET_ID" --arg specialtyId "$SPECIALTY_ID" '{
  petId: $petId,
  specialtyId: $specialtyId,
  priority: "routine",
  notes: "Phase 1 referral intake"
}')
referral_resp=$(curl -sS -X POST "$GATEWAY_BASE/vets/referrals" $owner_hdr -d "$referral_body")
echo "$referral_resp" | jq '{id, status, specialty_id}'
REFERRAL_ID=$(echo "$referral_resp" | jq -r '.id // empty')
if [[ -z "$REFERRAL_ID" ]]; then
  echo "ERROR: failed to create referral" >&2
  exit 1
fi

echo "[vets] PATCH /vets/referrals/$REFERRAL_ID assign"
assign_body=$(jq -n --arg assignedVetId "$VET_ID" '{assignedVetId: $assignedVetId}')
assign_resp=$(curl -sS -X PATCH "$GATEWAY_BASE/vets/referrals/$REFERRAL_ID" $vet_hdr -d "$assign_body")
echo "$assign_resp" | jq '{id, assigned_vet_id, status}'

echo "[vets] PATCH /vets/referrals/$REFERRAL_ID accept"
accept_resp=$(curl -sS -X PATCH "$GATEWAY_BASE/vets/referrals/$REFERRAL_ID" $vet_hdr -d '{"status":"accepted"}')
echo "$accept_resp" | jq '{id, status}'

echo "[vets] GET /vets/$VET_ID/availability/slots"
slots_resp=$(curl -sS "$GATEWAY_BASE/vets/$VET_ID/availability/slots?durationMin=30" $owner_hdr)
echo "$slots_resp" | jq '{count: (.data | length)}'
APPT_START=$(echo "$slots_resp" | jq -r '.data[0].start // empty')
if [[ -z "$APPT_START" ]]; then
  echo "ERROR: no appointment slot available for vet smoke" >&2
  exit 1
fi

echo "[vets] POST /appointments with specialty"
appointment_body=$(jq -n --arg vetId "$VET_ID" --arg specialtyId "$SPECIALTY_ID" --arg startsAt "$APPT_START" --arg petId "$PET_ID" '{
  vetId: $vetId,
  specialtyId: $specialtyId,
  startsAt: $startsAt,
  petId: $petId,
  durationMin: 30
}')
appointment_resp=$(curl -sS -X POST "$GATEWAY_BASE/appointments" $owner_hdr -d "$appointment_body")
echo "$appointment_resp" | jq '{id, session_id, status, starts_at}'
APPOINTMENT_ID=$(echo "$appointment_resp" | jq -r '.id // empty')
SESSION_ID=$(echo "$appointment_resp" | jq -r '.session_id // empty')
if [[ -z "$APPOINTMENT_ID" ]]; then
  echo "ERROR: failed to create appointment" >&2
  exit 1
fi

echo "[vets] POST /appointments/$APPOINTMENT_ID/transitions -> confirmed"
confirmed_resp=$(curl -sS -X POST "$GATEWAY_BASE/appointments/$APPOINTMENT_ID/transitions" $vet_hdr -d '{"to":"confirmed"}')
echo "$confirmed_resp" | jq '{id, status}'

echo "[vets] POST /appointments/$APPOINTMENT_ID/transitions -> active"
active_resp=$(curl -sS -X POST "$GATEWAY_BASE/appointments/$APPOINTMENT_ID/transitions" $vet_hdr -d '{"to":"active"}')
echo "$active_resp" | jq '{id, session_id, status}'
SESSION_ID=$(echo "$active_resp" | jq -r '.session_id // empty')

echo "[vets] GET /vets/me/queue after activation"
queue_active=$(curl -sS "$GATEWAY_BASE/vets/me/queue" $vet_hdr)
echo "$queue_active" | jq '{upcoming: (.upcomingAppointments | length), active: (.activeConsults | length), pendingNotes: (.pendingNotes | length), referrals: (.referrals | length)}'

echo "[vets] POST /appointments/$APPOINTMENT_ID/transitions -> completed"
completed_resp=$(curl -sS -X POST "$GATEWAY_BASE/appointments/$APPOINTMENT_ID/transitions" $vet_hdr -d '{"to":"completed"}')
echo "$completed_resp" | jq '{id, session_id, status}'
SESSION_ID=$(echo "$completed_resp" | jq -r '.session_id // empty')

if [[ -n "$SESSION_ID" && "$SESSION_ID" != "null" ]]; then
  echo "[vets] POST /sessions/$SESSION_ID/ratings"
  rating_resp=$(curl -sS -X POST "$GATEWAY_BASE/sessions/$SESSION_ID/ratings" $owner_hdr -d '{"score":5,"comment":"Phase 1 smoke rating"}')
  echo "$rating_resp" | jq '{id, session_id, score}'
fi

echo "[vets] GET /vets/$VET_ID/ratings"
ratings_resp=$(curl -sS "$GATEWAY_BASE/vets/$VET_ID/ratings" $owner_hdr)
echo "$ratings_resp" | jq '{count: (.data | length)}'

echo "[vets] GET /vets/$VET_ID/status"
status_resp=$(curl -sS "$GATEWAY_BASE/vets/$VET_ID/status" $vet_hdr)
echo "$status_resp" | jq '{is_approved, upcoming_appointments, active_consults, pending_notes, open_referrals}'

echo "[vets] Smoke complete"