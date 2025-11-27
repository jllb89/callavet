#!/usr/bin/env zsh
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

section() { print "\n== $1 =="; }
die() { print "ERROR: $1" >&2; exit 1 }
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
print "First delivery: $(echo "$FIRST" | jqsafe '.reason // .ok')"
print "Second delivery (should be ignored): $(echo "$SECOND" | jqsafe '.reason // .ok')"

# 2) Failure/refund: ensure no consumption on failure and credits reversed on refund
section "Webhook Failure & Refund paths"
# Payment failed
EVT_FAIL=$(jq -n '{id:"evt_sim_fail_001",type:"payment_intent.payment_failed",data:{object:{id:"pi_test_fail"}}}')
FAIL_RES=$(curl -sS -X POST -H "$INTERNAL_HEADER" -H 'Content-Type: application/json' \
  "$SERVER_URL/internal/stripe/event" -d "$EVT_FAIL")
print "Failure handled: $(echo "$FAIL_RES" | jqsafe '.ok // .reason')"
# Refund
EVT_REF=$(jq -n '{id:"evt_sim_refund_001",type:"charge.refunded",data:{object:{payment_intent:"pi_test_paid"}}}')
REF_RES=$(curl -sS -X POST -H "$INTERNAL_HEADER" -H 'Content-Type: application/json' \
  "$SERVER_URL/internal/stripe/event" -d "$EVT_REF")
print "Refund handled: $(echo "$REF_RES" | jqsafe '.ok // .reason')"

# 3) Concurrency: race sessions/start to draw last credit
section "Concurrency: simultaneous sessions/start on last credit"
# Ensure we have exactly 1 credit
ADJ=$(jq -n --arg code "${ITEM_CODE:-chat_unit}" '{code:$code,delta:0}')
# Set to 0 then +1 to arrive at exactly 1
curl -sS -X POST -H "$AUTH_HEADER" -H "$ADMIN_HEADER" -H 'Content-Type: application/json' \
  "$SERVER_URL/subscriptions/admin/overage/adjust-credits" -d "$(jq -n --arg code "${ITEM_CODE:-chat_unit}" '{code:$code,delta:-1000}')" >/dev/null
curl -sS -X POST -H "$AUTH_HEADER" -H "$ADMIN_HEADER" -H 'Content-Type: application/json' \
  "$SERVER_URL/subscriptions/admin/overage/adjust-credits" -d "$(jq -n --arg code "${ITEM_CODE:-chat_unit}" '{code:$code,delta:1}')" >/dev/null

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
print "Start#1 credit.used=$C1 overage=$O1"
print "Start#2 credit.used=$C2 overage=$O2"

print "\nAll webhook and concurrency checks completed"
