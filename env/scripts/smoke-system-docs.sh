#!/usr/bin/env bash
set -euo pipefail

# Smoke test: System + Docs + Internal Billing
# Always source .env.staging for consistent environment variables

set -a
source "$(dirname "$0")/../../.env.staging"
set +a

# Prefer `GATEWAY_BASE`; fallback to `SERVER_URL` if unset
BASE_URL="${GATEWAY_BASE:-$SERVER_URL}"
SB_TOKEN="${SB_ACCESS_TOKEN:-}"
AUTH_HEADER="Authorization: Bearer ${SB_TOKEN}"

pass=0
fail=0

function check() {
  local name="$1"; shift
  local method="$1"; shift
  local url="$1"; shift
  local hdrs=("-H" "Accept: application/json")
  # Include auth header if token present (internal endpoints may require it)
  if [[ -n "${SB_TOKEN}" ]]; then
    hdrs+=("-H" "$AUTH_HEADER")
  fi
  if [[ "$method" == "GET" ]]; then
    set +e
    resp=$(curl -s -S -X GET "${BASE_URL}${url}" "${hdrs[@]}")
    code=$?
    set -e
  else
    echo "Unsupported method: $method" >&2
    return 1
  fi
  if [[ $code -eq 0 && -n "$resp" ]]; then
    echo "PASS: $name"
    pass=$((pass+1))
  else
    echo "FAIL: $name"
    echo "$resp"
    fail=$((fail+1))
  fi
}

# System
check "health" GET "/health"
check "version" GET "/version"
check "time" GET "/time"

# Docs
check "openapi.yaml" GET "/openapi.yaml"
check "docs" GET "/docs"
check "openapi-chat-ws.yaml" GET "/openapi-chat-ws.yaml"
check "openapi-webhooks.yaml" GET "/openapi-webhooks.yaml"
check "docs/chat" GET "/docs/chat"
check "docs/webhooks" GET "/docs/webhooks"

# System DB
check "_db/status" GET "/_db/status"

# Internal Billing
check "internal/billing/health" GET "/internal/billing/health"

echo "Summary: PASS=$pass FAIL=$fail"
if [[ $fail -gt 0 ]]; then
  exit 1
fi
