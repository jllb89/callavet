#!/usr/bin/env bash
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
  printf "\n== %s ==\n" "$1"
}

die() {
  printf "ERROR: %s\n" "$1" >&2
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
printf "OpenAPI checks: OK\n"

# 2) Admin overage items: list -> upsert -> list confirm
section "Admin Overages: Items CRUD"
ITEM_CODE=${ITEM_CODE:-"chat_overage_unit"}
ITEM_NAME=${ITEM_NAME:-"Chat Overage Unit"}
ITEM_DESC=${ITEM_DESC:-"One-off overage unit for chat"}
ITEM_CURR=${ITEM_CURR:-"usd"}
ITEM_AMT=${ITEM_AMT:-500}
ITEM_ACTIVE=${ITEM_ACTIVE:-true}

printf "Listing items (pre)\n"
PRE_LIST_JSON=$(curl -sS -H "$AUTH_HEADER" -H "$ADMIN_HEADER" "$SERVER_URL/subscriptions/admin/overage/items" || true)
PRE_COUNT=$(echo "$PRE_LIST_JSON" | jqsafe '.items | length')
printf "Items before: %s\n" "${PRE_COUNT}"

printf "Upserting item %s\n" "${ITEM_CODE}"
UPSERT_BODY=$(jq -n --arg code "$ITEM_CODE" --arg name "$ITEM_NAME" --arg desc "$ITEM_DESC" --arg curr "$ITEM_CURR" --argjson amt $ITEM_AMT --argjson active $ITEM_ACTIVE '{code: $code, name: $name, description: $desc, currency: $curr, amount_cents: $amt, is_active: $active}')
UPSERT_JSON=$(curl -sS -X POST -H "$AUTH_HEADER" -H "$ADMIN_HEADER" -H "Content-Type: application/json" \
  -d "$UPSERT_BODY" "$SERVER_URL/subscriptions/admin/overage/items")
UPSERT_OK=$(echo "$UPSERT_JSON" | jqsafe '.ok')
[[ "$UPSERT_OK" == "true" ]] || die "Item upsert failed: $UPSERT_JSON"
printf "Upsert OK\n"

printf "Listing items (post)\n"
POST_LIST_JSON=$(curl -sS -H "$AUTH_HEADER" -H "$ADMIN_HEADER" "$SERVER_URL/subscriptions/admin/overage/items")
FOUND=$(echo "$POST_LIST_JSON" | jq -r --arg code "$ITEM_CODE" '.items | map(select(.code == $code)) | length')
[[ "$FOUND" != "0" ]] || die "Upserted item not found in list"
printf "Item present after upsert: OK\n"

# 3) Admin consumptions & purchases basic visibility
section "Admin Overages: Purchases & Consumptions listing"
PURCHASES_JSON=$(curl -sS -H "$AUTH_HEADER" -H "$ADMIN_HEADER" "$SERVER_URL/subscriptions/admin/overage/purchases")
P_COUNT=$(echo "$PURCHASES_JSON" | jqsafe '.purchases | length')
printf "Purchases count: %s\n" "${P_COUNT:-0}"
CONSUMPTIONS_JSON=$(curl -sS -H "$AUTH_HEADER" -H "$ADMIN_HEADER" "$SERVER_URL/subscriptions/admin/overage/consumptions")
C_COUNT=$(echo "$CONSUMPTIONS_JSON" | jqsafe '.consumptions | length')
printf "Consumptions count: %s\n" "${C_COUNT:-0}"

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
  printf "Overage flow present; payment fields OK\n"
else
  printf "No overage triggered; credits likely available. Skipping payment checks.\n"
fi

printf "\nAll checks completed\n"
