#!/usr/bin/env zsh
set -euo pipefail

: ${GATEWAY_BASE:?"Set GATEWAY_BASE (e.g., https://api.staging.callavet.mx)"}
: ${TOKEN:?"Set TOKEN (Bearer JWT)"}

hdr=(
  -H "Authorization: Bearer $TOKEN"
  -H "Content-Type: application/json"
)

print -- "[video] Creating room"
create_resp=$(curl -sS -X POST $hdr[@] --data '{"sessionId":"'$SESSION_ID'"}' "$GATEWAY_BASE/video/rooms")
print -- "$create_resp" | jq . 2>/dev/null || print -- "$create_resp"
room_id=$(print -- $create_resp | jq -r '.roomId // empty' 2>/dev/null || true)
if [[ -z "$room_id" ]]; then
  print -- "[video] Create failed"
  exit 1
fi
print -- "[video] Ending room id=$room_id"
end_resp=$(curl -sS -X POST $hdr[@] "$GATEWAY_BASE/video/rooms/$room_id/end")
print -- "$end_resp" | jq . 2>/dev/null || print -- "$end_resp"
print -- "[video] Smoke complete"
