#!/usr/bin/env zsh
set -euo pipefail

# Auto-source .env.staging if present
if [[ -f ./.env.staging ]]; then
  set -a && source ./.env.staging && set +a
fi

# Build AUTH_HEADER from SB_ACCESS_TOKEN if not explicitly provided
if [[ -z ${AUTH_HEADER:-} ]]; then
  if [[ -n ${SB_ACCESS_TOKEN:-} ]]; then
    export AUTH_HEADER="Authorization: Bearer ${SB_ACCESS_TOKEN}"
  else
    echo "ERROR: AUTH_HEADER or SB_ACCESS_TOKEN must be set" >&2
    exit 1
  fi
fi

# Required env vars (canonical names from .env.staging)
: ${SERVER_URL:?SERVER_URL is required}
: ${ADMIN_PRICING_SYNC_SECRET:?ADMIN_PRICING_SYNC_SECRET is required}

ADMIN_HEADER="x-admin-secret:${ADMIN_PRICING_SYNC_SECRET}"

section() {
  print "\n== $1 ==";
}

die() {
  print "ERROR: $1" >&2
  exit 1
}

jqsafe() {
  jq -r "$1" 2>/dev/null || echo ""
}

# 1) Validate OpenAPI updates presence (local file)
section "Validate OpenAPI includes admin and sessions/start payment schema"
OPENAPI_FILE="${PWD}/docs/openapi/openapi.yaml"
[[ -f "$OPENAPI_FILE" ]] || die "OpenAPI file not found at $OPENAPI_FILE"
if ! grep -q "/subscriptions/admin/overage/items" "$OPENAPI_FILE"; then die "Missing admin items path in OpenAPI"; fi
if ! grep -q "SessionStartResponse" "$OPENAPI_FILE"; then die "Missing SessionStartResponse schema"; fi
if ! grep -q "checkout_session_id" "$OPENAPI_FILE"; then die "Missing payment.checkout_session_id in schema"; fi
if ! grep -q "x-admin-secret" "$OPENAPI_FILE"; then die "Missing adminSecret security scheme"; fi
print "OpenAPI checks: OK"

# 2) Admin overage items: list -> upsert -> list confirm
section "Admin Overages: Items CRUD"
ITEM_CODE=${ITEM_CODE:-"chat_overage_unit"}
ITEM_NAME=${ITEM_NAME:-"Chat Overage Unit"}
ITEM_DESC=${ITEM_DESC:-"One-off overage unit for chat"}
ITEM_CURR=${ITEM_CURR:-"usd"}
ITEM_AMT=${ITEM_AMT:-500}
ITEM_ACTIVE=${ITEM_ACTIVE:-true}

print "Listing items (pre)"
PRE_LIST_JSON=$(curl -sS -H "$AUTH_HEADER" -H "$ADMIN_HEADER" "$SERVER_URL/subscriptions/admin/overage/items" || true)
PRE_COUNT=$(echo "$PRE_LIST_JSON" | jqsafe '.items | length')
print "Items before: ${PRE_COUNT}"

print "Upserting item ${ITEM_CODE}"
UPSERT_BODY=$(jq -n --arg code "$ITEM_CODE" --arg name "$ITEM_NAME" --arg desc "$ITEM_DESC" --arg curr "$ITEM_CURR" --argjson amt $ITEM_AMT --argjson active $ITEM_ACTIVE '{code: $code, name: $name, description: $desc, currency: $curr, amount_cents: $amt, is_active: $active}')
UPSERT_JSON=$(curl -sS -X POST -H "$AUTH_HEADER" -H "$ADMIN_HEADER" -H "Content-Type: application/json" \
  -d "$UPSERT_BODY" "$SERVER_URL/subscriptions/admin/overage/items")
UPSERT_OK=$(echo "$UPSERT_JSON" | jqsafe '.ok')
[[ "$UPSERT_OK" == "true" ]] || die "Item upsert failed: $UPSERT_JSON"
print "Upsert OK"

print "Listing items (post)"
POST_LIST_JSON=$(curl -sS -H "$AUTH_HEADER" -H "$ADMIN_HEADER" "$SERVER_URL/subscriptions/admin/overage/items")
FOUND=$(echo "$POST_LIST_JSON" | jq -r --arg code "$ITEM_CODE" '.items | map(select(.code == $code)) | length')
[[ "$FOUND" != "0" ]] || die "Upserted item not found in list"
print "Item present after upsert: OK"

# 3) Admin consumptions & purchases basic visibility
section "Admin Overages: Purchases & Consumptions listing"
PURCHASES_JSON=$(curl -sS -H "$AUTH_HEADER" -H "$ADMIN_HEADER" "$SERVER_URL/subscriptions/admin/overage/purchases")
P_COUNT=$(echo "$PURCHASES_JSON" | jqsafe '.purchases | length')
print "Purchases count: ${P_COUNT:-0}"
CONSUMPTIONS_JSON=$(curl -sS -H "$AUTH_HEADER" -H "$ADMIN_HEADER" "$SERVER_URL/subscriptions/admin/overage/consumptions")
C_COUNT=$(echo "$CONSUMPTIONS_JSON" | jqsafe '.consumptions | length')
print "Consumptions count: ${C_COUNT:-0}"

# 4) Sessions start: verify payment fields appear when overage is needed
section "Sessions: Start overage and validate payment fields"
# Attempt starting a chat session; expect overage when credits are exhausted
START_BODY='{"type":"chat"}'
START_JSON=$(curl -sS -X POST -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  -d "$START_BODY" "$SERVER_URL/sessions/start" || true)
OVERAGE=$(echo "$START_JSON" | jqsafe '.overage')
if [[ "$OVERAGE" == "true" ]]; then
  PAY_URL=$(echo "$START_JSON" | jqsafe '.payment.url')
  PAY_CS=$(echo "$START_JSON" | jqsafe '.payment.checkout_session_id')
  [[ -n "$PAY_URL" ]] || die "Missing payment.url on overage sessions/start"
  [[ -n "$PAY_CS" ]] || die "Missing payment.checkout_session_id on overage sessions/start"
  print "Overage flow present; payment fields OK"
else
  print "No overage triggered; credits likely available. Skipping payment checks."
fi

print "\nAll checks completed"
