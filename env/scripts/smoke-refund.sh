#!/usr/bin/env zsh
set -euo pipefail

# This smoke creates a test-mode PaymentIntent via Stripe, triggers a partial
# refund through the Gateway admin endpoint, then verifies the refund webhook
# was ingested by checking /internal/billing/health event counters.
#
# Required env:
# - GATEWAY_BASE (e.g., https://api.staging.callavet.mx)
# - TOKEN (Bearer JWT)
# - ADMIN_PRICING_SYNC_SECRET (admin header)
# - INTERNAL_STRIPE_EVENT_SECRET (for internal health endpoint)
# - STRIPE_SECRET_KEY (test mode secret key)
#
# Optional env:
# - REFUND_AMOUNT_CENTS (default: 200)
# - PI_AMOUNT_CENTS (default: 700)
# - CURRENCY (default: usd)

: ${GATEWAY_BASE:?'Set GATEWAY_BASE (e.g., https://api.staging.callavet.mx)'}
: ${TOKEN:?'Set TOKEN (Bearer JWT)'}
: ${ADMIN_PRICING_SYNC_SECRET:?'Set ADMIN_PRICING_SYNC_SECRET'}
: ${INTERNAL_STRIPE_EVENT_SECRET:?'Set INTERNAL_STRIPE_EVENT_SECRET'}
: ${STRIPE_SECRET_KEY:?'Set STRIPE_SECRET_KEY (Stripe test secret)'}

REFUND_AMOUNT_CENTS=${REFUND_AMOUNT_CENTS:-200}
PI_AMOUNT_CENTS=${PI_AMOUNT_CENTS:-700}
CURRENCY=${CURRENCY:-usd}

hdr=(
  -H "Authorization: Bearer $TOKEN"
  -H "x-admin-secret: $ADMIN_PRICING_SYNC_SECRET"
  -H "Content-Type: application/json"
)

section() { print -- "\n== $1 =="; }
jqsafe() { jq -r "$1" 2>/dev/null || true }

echo "Using currency=$CURRENCY PI_AMOUNT=$PI_AMOUNT_CENTS REFUND_AMOUNT=$REFUND_AMOUNT_CENTS"

# 1) Baseline internal billing health
section "Baseline billing health"
BASE_HEALTH=$(curl -sS -H "x-internal-secret: $INTERNAL_STRIPE_EVENT_SECRET" "$GATEWAY_BASE/internal/billing/health")
print -- "$BASE_HEALTH" | jq . 2>/dev/null || print -- "$BASE_HEALTH"
BASE_REFUNDS=$(print -- "$BASE_HEALTH" | jqsafe '.event_counts["charge.refunded"] // 0')

# 2) Create a test PaymentIntent (confirmed) via Stripe API
section "Create test PaymentIntent (Stripe)"
PI_RESP=$(curl -sS https://api.stripe.com/v1/payment_intents \
  -u "$STRIPE_SECRET_KEY:" \
  -d amount="$PI_AMOUNT_CENTS" \
  -d currency="$CURRENCY" \
  -d "payment_method_types[]=card" \
  -d payment_method="pm_card_visa" \
  -d confirm=true \
  -d description="smoke-refund")
print -- "$PI_RESP" | jq . 2>/dev/null || print -- "$PI_RESP"
PI_ID=$(print -- "$PI_RESP" | jqsafe '.id')
PI_STATUS=$(print -- "$PI_RESP" | jqsafe '.status')
if [[ -z "$PI_ID" || "$PI_ID" == "null" ]]; then
  print -- "ERROR: Failed to create PaymentIntent" >&2
  exit 1
fi
print -- "Created PI=$PI_ID status=$PI_STATUS"

# 3) Trigger partial refund via admin endpoint
section "Trigger admin refund"
REQ_ID="smoke-$(date +%s)-$RANDOM"
REF_REQ=$(printf '{"paymentId":"%s","amount":%d,"reason":"requested_by_customer","requestId":"%s"}' "$PI_ID" "$REFUND_AMOUNT_CENTS" "$REQ_ID")
REF_RES=$(curl -sS -X POST $hdr[@] --data "$REF_REQ" "$GATEWAY_BASE/admin/refunds")
print -- "$REF_RES" | jq . 2>/dev/null || print -- "$REF_RES"
REF_ID=$(print -- "$REF_RES" | jqsafe '.refund_id')
if [[ -z "$REF_ID" || "$REF_ID" == "null" ]]; then
  print -- "ERROR: Refund creation failed" >&2
  exit 1
fi
print -- "Refund created refund_id=$REF_ID"

# 4) Poll Stripe for refund status
section "Verify refund on Stripe"
for i in {1..10}; do
  R=$(curl -sS https://api.stripe.com/v1/refunds/$REF_ID -u "$STRIPE_SECRET_KEY:")
  STATUS=$(print -- "$R" | jqsafe '.status')
  AMT=$(print -- "$R" | jqsafe '.amount')
  print -- "Attempt $i: refund status=$STATUS amount=$AMT"
  [[ "$STATUS" == "succeeded" ]] && break
  sleep 2
done

# 5) Poll internal billing health to see refund event recorded
section "Verify webhook ingestion via /internal/billing/health"
for i in {1..10}; do
  H=$(curl -sS -H "x-internal-secret: $INTERNAL_STRIPE_EVENT_SECRET" "$GATEWAY_BASE/internal/billing/health")
  CUR=$(print -- "$H" | jqsafe '.event_counts["charge.refunded"] // 0')
  print -- "Attempt $i: charge.refunded count=$CUR (baseline=$BASE_REFUNDS)"
  if [[ "$CUR" != "null" && "$CUR" -ge "$((BASE_REFUNDS+1))" ]]; then
    print -- "Webhook ingestion confirmed"
    break
  fi
  sleep 2
done

print -- "\nSmoke refund completed: PI=$PI_ID REFUND=$REF_ID"
