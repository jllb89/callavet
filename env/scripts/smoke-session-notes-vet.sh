#!/usr/bin/env zsh
set -euo pipefail

: ${GATEWAY_BASE:?"Set GATEWAY_BASE (e.g., https://api.staging.callavet.mx)"}
: ${TOKEN:?"Set TOKEN (Bearer JWT)"}
: ${SESSION_ID:=}
: ${PET_ID:=}

hdr=(
  -H "Authorization: Bearer $TOKEN"
  -H "Content-Type: application/json"
)

if [[ -z "$PET_ID" ]]; then
  PET_ID=$(curl -sS -H "Authorization: Bearer $TOKEN" "$GATEWAY_BASE/pets" | jq -r '.data[0].id // empty' 2>/dev/null || true)
fi

if [[ -z "$SESSION_ID" ]]; then
  SESSION_ID=$(curl -sS -X POST $hdr[@] --data '{"kind":"chat"}' "$GATEWAY_BASE/sessions/start" | jq -r '.sessionId // empty' 2>/dev/null || true)
fi

if [[ -z "$SESSION_ID" ]]; then
  print -- "ERROR: SESSION_ID is required (set SESSION_ID or ensure sessions/start returns sessionId)"
  exit 1
fi

if [[ -z "$PET_ID" ]]; then
  print -- "ERROR: PET_ID is required (set PET_ID or ensure /pets has at least one pet)"
  exit 1
fi

print -- "[session-notes-vet] Checking notes visibility for session=$SESSION_ID"
list_resp=$(curl -sS -X GET $hdr[@] "$GATEWAY_BASE/sessions/$SESSION_ID/notes")
print -- "$list_resp" | jq . 2>/dev/null || print -- "$list_resp"

count=$(print -- $list_resp | jq -r '.data | length' 2>/dev/null || echo 0)
print -- "[session-notes-vet] Notes count=$count"

print -- "[session-notes-vet] Creating a vet-authored note to verify author visibility"
post_resp=$(curl -sS -X POST $hdr[@] \
  --data "{\"summary_text\":\"Vet authored note\",\"plan_summary\":\"Context pre-consult\",\"pet_id\":\"$PET_ID\"}" \
  "$GATEWAY_BASE/sessions/$SESSION_ID/notes")
print -- "$post_resp" | jq . 2>/dev/null || print -- "$post_resp"

note_id=$(print -- $post_resp | jq -r '.id // empty' 2>/dev/null || true)
if [[ -z "$note_id" ]]; then
  print -- "[session-notes-vet] POST failed; reason: $(print -- $post_resp | jq -r '.reason // "unknown"' 2>/dev/null)"
  exit 1
fi
print -- "[session-notes-vet] Created note id=$note_id"

print -- "[session-notes-vet] Re-list notes for session=$SESSION_ID"
list2_resp=$(curl -sS -X GET $hdr[@] "$GATEWAY_BASE/sessions/$SESSION_ID/notes")
print -- "$list2_resp" | jq . 2>/dev/null || print -- "$list2_resp"
count2=$(print -- $list2_resp | jq -r '.data | length' 2>/dev/null || echo 0)
print -- "[session-notes-vet] Notes count after create=$count2"

print -- "[session-notes-vet] Smoke complete"
