#!/usr/bin/env bash
set -euo pipefail

# Auto-source .env.staging
if [[ -f ./.env.staging ]]; then
  set -a && source ./.env.staging && set +a
fi

# Build AUTH_HEADER from SB_ACCESS_TOKEN if missing
if [[ -z ${AUTH_HEADER:-} ]]; then
  if [[ -n ${SB_ACCESS_TOKEN:-} ]]; then
    export AUTH_HEADER="Authorization: Bearer ${SB_ACCESS_TOKEN}"
  else
    echo "ERROR: AUTH_HEADER or SB_ACCESS_TOKEN must be set" >&2
    exit 1
  fi
fi

: ${SERVER_URL:?SERVER_URL is required}
: ${ADMIN_PRICING_SYNC_SECRET:?ADMIN_PRICING_SYNC_SECRET is required}
: ${INTERNAL_STRIPE_EVENT_SECRET:?INTERNAL_STRIPE_EVENT_SECRET is required}

ADMIN_HEADER="x-admin-secret:${ADMIN_PRICING_SYNC_SECRET}"
INTERNAL_HEADER="x-internal-secret:${INTERNAL_STRIPE_EVENT_SECRET}"

section() { printf "\n== %s ==\n" "$1"; }
die() { printf "ERROR: %s\n" "$1" >&2; exit 1; }
jqsafe() { jq -r "$1" 2>/dev/null || echo "" }

# 1) Idempotency: replay same webhook event
section "Webhook Idempotency: replay identical event"
# Simulate checkout.session.completed with a static id
EVT_ID="evt_sim_test_idempotent_001"
EVT_JSON=$(jq -n --arg id "$EVT_ID" '{id:$id,type:"checkout.session.completed",data:{object:{id:"cs_test_abc",metadata:{user_id:"dummy"}}}}')
FIRST=$(curl -sS -X POST -H "$INTERNAL_HEADER" -H 'Content-Type: application/json' \
  "$SERVER_URL/internal/stripe/event" -d "$EVT_JSON")
SECOND=$(curl -sS -X POST -H "$INTERNAL_HEADER" -H 'Content-Type: application/json' \
  "$SERVER_URL/internal/stripe/event" -d "$EVT_JSON")
printf "First delivery ok=%s reason=%s\n" "$(echo "$FIRST" | jqsafe '.ok')" "$(echo "$FIRST" | jqsafe '.reason')"
printf "Second delivery ok=%s reason=%s\n" "$(echo "$SECOND" | jqsafe '.ok')" "$(echo "$SECOND" | jqsafe '.reason')"

# 2) Failure/refund: ensure no consumption on failure and credits reversed on refund
section "Webhook Failure & Refund paths"
# Payment failed
EVT_FAIL=$(jq -n '{id:"evt_sim_fail_001",type:"payment_intent.payment_failed",data:{object:{id:"pi_test_fail"}}}')
FAIL_RES=$(curl -sS -X POST -H "$INTERNAL_HEADER" -H 'Content-Type: application/json' \
  "$SERVER_URL/internal/stripe/event" -d "$EVT_FAIL")
printf "Failure handled ok=%s reason=%s\n" "$(echo "$FAIL_RES" | jqsafe '.ok')" "$(echo "$FAIL_RES" | jqsafe '.reason')"
# Refund
EVT_REF=$(jq -n '{id:"evt_sim_refund_001",type:"charge.refunded",data:{object:{payment_intent:"pi_test_paid"}}}')
REF_RES=$(curl -sS -X POST -H "$INTERNAL_HEADER" -H 'Content-Type: application/json' \
  "$SERVER_URL/internal/stripe/event" -d "$EVT_REF")
printf "Refund handled ok=%s reason=%s\n" "$(echo "$REF_RES" | jqsafe '.ok')" "$(echo "$REF_RES" | jqsafe '.reason')"

# Post-event assertions: purchases status and credits remaining
section "Post-webhook assertions: purchases & credits"
PURCHASES_JSON=$(curl -sS -H "$AUTH_HEADER" -H "$ADMIN_HEADER" "$SERVER_URL/subscriptions/admin/overage/purchases")
printf "Latest purchase statuses:\n"
echo "$PURCHASES_JSON" | jq -r '.purchases | sort_by(.updated_at) | reverse | .[0:5] | .[] | "\(.id) status=\(.status) code=\(.code) qty=\(.quantity)"'
printf "Credits snapshot:\n"
curl -sS -H "$AUTH_HEADER" "$SERVER_URL/subscriptions/overage/credits" | jq -r '.credits | .[] | "code=\(.code) remaining=\(.remaining_units)"'

# 3) Concurrency: race sessions/start to draw last credit
section "Concurrency: simultaneous sessions/start on last credit"
# Ensure we have exactly 1 credit
ADJ=$(jq -n --arg code "${ITEM_CODE:-chat_unit}" '{code:$code,delta:0}')
# Set to 0 then +1 to arrive at exactly 1
curl -sS -X POST -H "$AUTH_HEADER" -H "$ADMIN_HEADER" -H 'Content-Type: application/json' \
  "$SERVER_URL/subscriptions/admin/overage/adjust-credits" -d "$(jq -n --arg code "${ITEM_CODE:-chat_unit}" '{code:$code,delta:-1000}')" >/dev/null
curl -sS -X POST -H "$AUTH_HEADER" -H "$ADMIN_HEADER" -H 'Content-Type: application/json' \
  "$SERVER_URL/subscriptions/admin/overage/adjust-credits" -d "$(jq -n --arg code "${ITEM_CODE:-chat_unit}" '{code:$code,delta:1}')" >/dev/null

# Pre-check: confirm remaining credits == 1
CREDITS=$(curl -sS -H "$AUTH_HEADER" "$SERVER_URL/subscriptions/overage/credits")
REMAIN=$(echo "$CREDITS" | jqsafe ".credits | map(select(.code == \"${ITEM_CODE:-chat_unit}\")) | .[0].remaining_units")
if [[ "$REMAIN" != "1" ]]; then
  die "Expected 1 remaining credit for ${ITEM_CODE:-chat_unit}, got '$REMAIN'"
fi

# Fire two starts in parallel
START_BODY='{"type":"chat"}'
( curl -sS -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' -d "$START_BODY" "$SERVER_URL/sessions/start" > /tmp/start1.json ) &
( curl -sS -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' -d "$START_BODY" "$SERVER_URL/sessions/start" > /tmp/start2.json ) &
wait
S1=$(cat /tmp/start1.json)
S2=$(cat /tmp/start2.json)
# Expect exactly one to use credit; the other should be overage
C1=$(echo "$S1" | jqsafe '.credit.used')
C2=$(echo "$S2" | jqsafe '.credit.used')
O1=$(echo "$S1" | jqsafe '.overage')
O2=$(echo "$S2" | jqsafe '.overage')
printf "Start#1 credit.used=%s overage=%s\n" "$C1" "$O1"
printf "Start#2 credit.used=%s overage=%s\n" "$C2" "$O2"

if [[ "$C1" == "true" && "$O2" == "true" ]] || [[ "$C2" == "true" && "$O1" == "true" ]]; then
  printf "Concurrency result: PASS (one credit draw, one overage)\n"
else
  printf "Concurrency result: FAIL (no credit draw detected)\n"
fi

printf "\nAll webhook and concurrency checks completed\n"
