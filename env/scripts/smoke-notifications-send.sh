#!/usr/bin/env zsh
set -euo pipefail

: ${GATEWAY_BASE:?'Set GATEWAY_BASE (e.g., https://cav-gateway-staging-ugvx.onrender.com)'}
# Prefer AUTH_HEADER (e.g., "Authorization: Bearer $SB_ACCESS_TOKEN"). Fallback to TOKEN.
if [[ -z "${AUTH_HEADER:-}" ]]; then
  : ${TOKEN:?'Set TOKEN (Bearer JWT) or AUTH_HEADER'}
  export AUTH_HEADER="Authorization: Bearer ${TOKEN#Bearer }"
fi

hdr=(
  -H "$AUTH_HEADER"
  -H "Content-Type: application/json"
)

# Sandbox mode avoids actually sending an email in SendGrid
print -- "[notifications] Sending email via /notifications/send (sandbox mode)"
payload='{
  "to": "example-recipient@example.com",
  "subject": "Sandbox smoke test",
  "text": "This is a sandbox test.",
  "sandbox": true
}'
resp=$(curl -sS -X POST $hdr[@] --data "$payload" "$GATEWAY_BASE/notifications/send")
if [[ -z "${SENDGRID_API_KEY:-}" ]]; then
  print -- "[notifications] Warning: SENDGRID_API_KEY not set in env; endpoint will 500 on real gateway unless configured in Render."
fi
print -- "$resp" | jq . 2>/dev/null || print -- "$resp"
print -- "[notifications] Done"
