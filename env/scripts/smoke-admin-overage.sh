#!/usr/bin/env zsh
set -euo pipefail

: ${SERVER_URL:?Need to set SERVER_URL}
: ${AUTH_HEADER:?Need to set AUTH_HEADER}
: ${ADMIN_PRICING_SYNC_SECRET:=}
: ${ADMIN_SECRET:=}
[[ -z "$ADMIN_PRICING_SYNC_SECRET$ADMIN_SECRET" ]] && { echo "Need to set ADMIN_PRICING_SYNC_SECRET or ADMIN_SECRET"; exit 1; }
ADMIN_GUARD=${ADMIN_PRICING_SYNC_SECRET:-$ADMIN_SECRET}

json() { jq -r "$1" 2>/dev/null || true }
log() { echo "[$(date +%H:%M:%S)] $*" }

log "Admin guard: expect forbidden without secret"
curl -sS -H "$AUTH_HEADER" "$SERVER_URL/subscriptions/admin/overage/purchases" | jq '.ok,.reason'

log "Admin guard: expect success with secret"
curl -sS -H "$AUTH_HEADER" -H "x-admin-secret:$ADMIN_GUARD" "$SERVER_URL/subscriptions/admin/overage/purchases" | jq '.ok,.purchases | length'

log "Start overage chat session (no credits/entitlements)"
RESP=$(curl -sS -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  "$SERVER_URL/sessions/start" -d '{"type":"chat"}')
echo "$RESP" | jq
SESSION_ID=$(echo "$RESP" | jq -r '.session?.id // .session_id // .id // empty')
PAY_URL=$(echo "$RESP" | jq -r '.payment?.url // empty')
log "session_id=$SESSION_ID payment.url=$PAY_URL"

if [[ -z "$PAY_URL" ]]; then
  log "No payment.url returned; ensure credits are zero before running."
else
  log "Found payment.url; proceed to list admin purchases bound to session"
  curl -sS -H "$AUTH_HEADER" -H "x-admin-secret:$ADMIN_GUARD" \
    "$SERVER_URL/subscriptions/admin/overage/purchases" | jq '[.purchases[] | select(.original_session_id=="'$SESSION_ID'")]'
fi

log "Attempt double consume on same purchase (should fail)"
# Find a paid purchase to test duplicate linking; fallback to simulate by calling consume twice
PAID_PURCHASE=$(curl -sS -H "$AUTH_HEADER" -H "x-admin-secret:$ADMIN_GUARD" \
  "$SERVER_URL/subscriptions/admin/overage/purchases" | jq -r '.purchases[] | select(.status=="paid") | .id' | head -n1)
if [[ -n "$PAID_PURCHASE" ]]; then
  log "Using paid purchase $PAID_PURCHASE for duplicate consume test"
  BODY='{"mode":"purchase","purchase_id":"'$PAID_PURCHASE'","session_id":"'$SESSION_ID'","type":"chat"}'
  curl -sS -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
    "$SERVER_URL/subscriptions/overage/consume" -d "$BODY" | jq
  log "Second attempt (should be prevented by unique index)"
  curl -sS -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
    "$SERVER_URL/subscriptions/overage/consume" -d "$BODY" | jq
else
  log "No paid purchase found to test duplicate consume; skip."
fi

log "Webhook idempotency check (requires Stripe CLI forwarding)"
log "Re-send same checkout.session.completed in your Stripe terminal; expect skipped:true"

log "Done"
