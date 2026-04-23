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

# New admin ops
print -- "[admin] Grant credits (stub)"
grant_payload='{"userId":"'$userId'","code":"overage_chat","delta":5}'
grant=$(curl -sS -X POST $hdr[@] -H "Content-Type: application/json" --data "$grant_payload" "$GATEWAY_BASE/admin/credits/grant")
print -- "$grant" | jq . 2>/dev/null || print -- "$grant"

print -- "[admin] Create refund (stub)"
refund_payload='{"paymentId":"test_payment_id","amount":500,"reason":"manual_smoke"}'
refund=$(curl -sS -X POST $hdr[@] -H "Content-Type: application/json" --data "$refund_payload" "$GATEWAY_BASE/admin/refunds")
print -- "$refund" | jq . 2>/dev/null || print -- "$refund"

print -- "[admin] Approve vet (stub)"
vetId="00000000-0000-0000-0000-000000000000"
approve=$(curl -sS -X POST $hdr[@] "$GATEWAY_BASE/admin/vets/$vetId/approve")
print -- "$approve" | jq . 2>/dev/null || print -- "$approve"

print -- "[admin] Upsert plan (stub)"
plan_payload='{"code":"chat_unit","name":"Chat Unit","price_cents":299,"currency":"usd"}'
plan=$(curl -sS -X POST $hdr[@] -H "Content-Type: application/json" --data "$plan_payload" "$GATEWAY_BASE/admin/plans")
print -- "$plan" | jq . 2>/dev/null || print -- "$plan"

print -- "[admin] Analytics usage (stub)"
analytics=$(curl -sS -X GET $hdr[@] "$GATEWAY_BASE/admin/analytics/usage")
print -- "$analytics" | jq . 2>/dev/null || print -- "$analytics"

print -- "[admin] Notification events"
events=$(curl -sS -X GET $hdr[@] "$GATEWAY_BASE/admin/notifications/events?limit=5")
print -- "$events" | jq . 2>/dev/null || print -- "$events"

print -- "[admin] Audit logs"
audit=$(curl -sS -X GET $hdr[@] "$GATEWAY_BASE/admin/audit/logs?limit=5")
print -- "$audit" | jq . 2>/dev/null || print -- "$audit"

print -- "[admin] Export sessions"
exp_sessions=$(curl -sS -X GET $hdr[@] "$GATEWAY_BASE/admin/export/sessions?limit=5")
print -- "$exp_sessions" | jq . 2>/dev/null || print -- "$exp_sessions"

print -- "[admin] Export notes"
exp_notes=$(curl -sS -X GET $hdr[@] "$GATEWAY_BASE/admin/export/notes?limit=5")
print -- "$exp_notes" | jq . 2>/dev/null || print -- "$exp_notes"

print -- "[admin] Ops dashboard"
ops=$(curl -sS -X GET $hdr[@] "$GATEWAY_BASE/admin/ops/dashboard")
print -- "$ops" | jq . 2>/dev/null || print -- "$ops"
