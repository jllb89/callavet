#!/usr/bin/env zsh
set -euo pipefail

: ${GATEWAY_BASE:?"Set GATEWAY_BASE (e.g., https://api.staging.callavet.mx)"}
: ${TOKEN:?"Set TOKEN (Bearer JWT)"}
: ${ADMIN_PRICING_SYNC_SECRET:?"Set ADMIN_PRICING_SYNC_SECRET (admin secret)"}

hdr=(
  -H "Authorization: Bearer $TOKEN"
  -H "x-admin-secret: $ADMIN_PRICING_SYNC_SECRET"
)

print -- "[admin] List users"
resp=$(curl -sS -X GET $hdr[@] "$GATEWAY_BASE/admin/users?limit=5")
print -- "$resp" | jq . 2>/dev/null || print -- "$resp"

userId=$(print -- "$resp" | jq -r '.data[0].id' 2>/dev/null || true)
if [[ -n "$userId" && "$userId" != "null" ]]; then
  print -- "[admin] User detail $userId"
  det=$(curl -sS -X GET $hdr[@] "$GATEWAY_BASE/admin/users/$userId")
  print -- "$det" | jq . 2>/dev/null || print -- "$det"
fi

print -- "[admin] List subscriptions"
subs=$(curl -sS -X GET $hdr[@] "$GATEWAY_BASE/admin/subscriptions?limit=5")
print -- "$subs" | jq . 2>/dev/null || print -- "$subs"

print -- "[admin] Smoke complete"
