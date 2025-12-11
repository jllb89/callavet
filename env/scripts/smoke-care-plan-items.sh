#!/usr/bin/env zsh
set -euo pipefail

: ${GATEWAY_BASE:?"Set GATEWAY_BASE (e.g., https://api.staging.callavet.mx)"}
: ${TOKEN:?"Set TOKEN (Bearer JWT)"}
: ${PLAN_ID:?"Set PLAN_ID (care_plans.id)"}

hdr=(
  -H "Authorization: Bearer $TOKEN"
  -H "Content-Type: application/json"
)

print -- "[care-plan-items] Creating item on plan=$PLAN_ID"
create_resp=$(curl -sS -X POST $hdr[@] \
  --data '{"type":"consult","description":"Follow-up consult","price_cents":15000}' \
  "$GATEWAY_BASE/care-plans/$PLAN_ID/items")
print -- "$create_resp" | jq . 2>/dev/null || print -- "$create_resp"

item_id=$(print -- $create_resp | jq -r '.id // empty' 2>/dev/null || true)
if [[ -z "$item_id" ]]; then
  print -- "[care-plan-items] Create failed or unauthorized; reason: $(print -- $create_resp | jq -r '.reason // "unknown"' 2>/dev/null)"
  exit 1
fi
print -- "[care-plan-items] Created item id=$item_id"

print -- "[care-plan-items] Listing items for plan=$PLAN_ID"
list_resp=$(curl -sS -X GET $hdr[@] "$GATEWAY_BASE/care-plans/$PLAN_ID/items")
print -- "$list_resp" | jq . 2>/dev/null || print -- "$list_resp"

count=$(print -- $list_resp | jq -r '.data | length' 2>/dev/null || echo 0)
print -- "[care-plan-items] Items count=$count"

print -- "[care-plan-items] Patch fulfill item id=$item_id"
patch_resp=$(curl -sS -X PATCH $hdr[@] \
  --data '{"fulfilled":true}' \
  "$GATEWAY_BASE/care-plans/items/$item_id")
print -- "$patch_resp" | jq . 2>/dev/null || print -- "$patch_resp"

fulfilled=$(print -- $patch_resp | jq -r '.fulfilled // "false"' 2>/dev/null || echo false)
print -- "[care-plan-items] Fulfilled=$fulfilled"

print -- "[care-plan-items] Smoke complete"
