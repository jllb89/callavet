#!/usr/bin/env bash
set -euo pipefail

# Smoke test: Auth & Profile (me/*)
# Always source .env.staging for consistent environment variables

set -a
source "$(dirname "$0")/../../.env.staging"
set +a

BASE_URL="${GATEWAY_BASE:-$SERVER_URL}"
SB_TOKEN="${SB_ACCESS_TOKEN:-}"
AUTH_HEADER="Authorization: Bearer ${SB_TOKEN}"
JSON_HEADER=("-H" "Content-Type: application/json")

pass=0
fail=0

function check_get() {
  local name="$1"; shift
  local path="$1"; shift
  local hdrs=("-H" "Accept: application/json")
  if [[ -n "$SB_TOKEN" ]]; then
    hdrs+=("-H" "$AUTH_HEADER")
  fi
  set +e
  resp=$(curl -s -S -X GET "${BASE_URL}${path}" "${hdrs[@]}")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$resp" ]]; then
    echo "PASS: $name"
    pass=$((pass+1))
  else
    echo "FAIL: $name"
    echo "$resp"
    fail=$((fail+1))
  fi
}

function check_post() {
  local name="$1"; shift
  local path="$1"; shift
  local body="$1"; shift
  local hdrs=("-H" "Accept: application/json" "${JSON_HEADER[@]}")
  if [[ -n "$SB_TOKEN" ]]; then
    hdrs+=("-H" "$AUTH_HEADER")
  fi
  set +e
  resp=$(curl -s -S -X POST "${BASE_URL}${path}" "${hdrs[@]}" -d "$body")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$resp" ]]; then
    echo "PASS: $name"
    pass=$((pass+1))
  else
    echo "FAIL: $name"
    echo "$resp"
    fail=$((fail+1))
  fi
}

function check_patch() {
  local name="$1"; shift
  local path="$1"; shift
  local body="$1"; shift
  local hdrs=("-H" "Accept: application/json" "${JSON_HEADER[@]}")
  if [[ -n "$SB_TOKEN" ]]; then
    hdrs+=("-H" "$AUTH_HEADER")
  fi
  set +e
  resp=$(curl -s -S -X PATCH "${BASE_URL}${path}" "${hdrs[@]}" -d "$body")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$resp" ]]; then
    echo "PASS: $name"
    pass=$((pass+1))
  else
    echo "FAIL: $name"
    echo "$resp"
    fail=$((fail+1))
  fi
}

function check_put() {
  local name="$1"; shift
  local path="$1"; shift
  local body="$1"; shift
  local hdrs=("-H" "Accept: application/json" "${JSON_HEADER[@]}")
  if [[ -n "$SB_TOKEN" ]]; then
    hdrs+=("-H" "$AUTH_HEADER")
  fi
  set +e
  resp=$(curl -s -S -X PUT "${BASE_URL}${path}" "${hdrs[@]}" -d "$body")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$resp" ]]; then
    echo "PASS: $name"
    pass=$((pass+1))
  else
    echo "FAIL: $name"
    echo "$resp"
    fail=$((fail+1))
  fi
}

function check_delete() {
  local name="$1"; shift
  local path="$1"; shift
  local hdrs=("-H" "Accept: application/json")
  if [[ -n "$SB_TOKEN" ]]; then
    hdrs+=("-H" "$AUTH_HEADER")
  fi
  set +e
  resp=$(curl -s -S -X DELETE "${BASE_URL}${path}" "${hdrs[@]}")
  code=$?
  set -e
  # DELETE can return empty body (204)
  if [[ $code -eq 0 ]]; then
    echo "PASS: $name"
    pass=$((pass+1))
  else
    echo "FAIL: $name"
    echo "$resp"
    fail=$((fail+1))
  fi
}

# Me
check_get "me" "/me"
check_patch "me patch" "/me" '{"display_name":"Smoke Test","locale":"en"}'

# Security sessions
check_get "me security sessions" "/me/security/sessions"

# Logout
check_post "logout all" "/me/security/logout-all" '{}'
check_post "logout all supabase" "/me/security/logout-all-supabase" '{}'

# Billing profile
check_get "billing profile" "/me/billing-profile"
check_put "billing profile upsert" "/me/billing-profile" '{"country":"MX","name":"Smoke Tester","email":"tester@example.com","tax_id":"XAXX010101000","address":{"line1":"Av. Test 123","city":"CDMX","state":"CDMX","postal_code":"01000"}}'

# Payment methods
check_post "payment method attach" "/me/billing/payment-method/attach" '{}'
# For detach, require a pmId (placeholder); skip unless provided via env
PM_ID="${PM_ID:-}"
if [[ -n "$PM_ID" ]]; then
  check_delete "payment method detach" "/me/billing/payment-method/$PM_ID"
else
  echo "SKIP: payment method detach (set PM_ID to run)"
fi

echo "Summary: PASS=$pass FAIL=$fail"
if [[ $fail -gt 0 ]]; then
  exit 1
fi
