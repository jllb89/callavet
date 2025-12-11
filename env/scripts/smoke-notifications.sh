#!/usr/bin/env zsh
set -euo pipefail

: ${GATEWAY_BASE:?"Set GATEWAY_BASE (e.g., https://api.staging.callavet.mx)"}
: ${TOKEN:?"Set TOKEN (Bearer JWT)"}

hdr=(
  -H "Authorization: Bearer $TOKEN"
  -H "Content-Type: application/json"
)

print -- "[notifications] Sending test notification"
resp=$(curl -sS -X POST $hdr[@] \
  --data '{"channel":"email","to":"lopezb.jl@gmail.com","message":"Smoke test"}' \
  "$GATEWAY_BASE/notifications/test")
print -- "$resp" | jq . 2>/dev/null || print -- "$resp"
print -- "[notifications] Smoke complete"
