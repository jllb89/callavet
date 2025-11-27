#!/usr/bin/env bash
set -euo pipefail

# Smoke test: Plans & Subscriptions (Group 3)
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

function ok(){ echo "PASS: $1"; pass=$((pass+1)); }
function bad(){ echo "FAIL: $1"; echo "$2"; fail=$((fail+1)); }

function curl_get(){
  local path="$1"; shift
  local hdrs=("-H" "Accept: application/json")
  if [[ -n "$SB_TOKEN" ]]; then hdrs+=("-H" "$AUTH_HEADER"); fi
  curl -s -S -X GET "${BASE_URL}${path}" "${hdrs[@]}"
}

function curl_post(){
  local path="$1"; shift
  local body="$1"; shift
  local hdrs=("-H" "Accept: application/json" "${JSON_HEADER[@]}")
  if [[ -n "$SB_TOKEN" ]]; then hdrs+=("-H" "$AUTH_HEADER"); fi
  curl -s -S -X POST "${BASE_URL}${path}" "${hdrs[@]}" -d "$body"
}

# Public plans
set +e
resp=$(curl_get "/plans")
code=$?
set -e
if [[ $code -eq 0 && -n "$resp" ]]; then ok "plans"; else bad "plans" "$resp"; fi

set +e
resp=$(curl_get "/plans/basic")
code=$?
set -e
if [[ $code -eq 0 && -n "$resp" ]]; then ok "plans/{code}"; else bad "plans/{code}" "$resp"; fi

# Auth-required endpoints
set +e
resp=$(curl_get "/subscriptions/my")
code=$?
set -e
if [[ $code -eq 0 && -n "$resp" ]]; then ok "subscriptions/my"; else bad "subscriptions/my" "$resp"; fi

set +e
resp=$(curl_get "/subscriptions/usage/current")
code=$?
set -e
if [[ $code -eq 0 && -n "$resp" ]]; then ok "subscriptions/usage/current"; else bad "subscriptions/usage/current" "$resp"; fi

# Portal
set +e
resp=$(curl_post "/subscriptions/portal" '{}')
code=$?
set -e
if [[ $code -eq 0 && -n "$resp" ]]; then ok "subscriptions/portal"; else bad "subscriptions/portal" "$resp"; fi

# Checkout (core subscription) — optional; run if PLAN_CODE provided
PLAN_CODE="${PLAN_CODE:-basic}"
run_checkout_core="${RUN_CHECKOUT_CORE:-false}"
if [[ "$run_checkout_core" == "true" ]]; then
  set +e
  resp=$(curl_post "/subscriptions/checkout" "{\"code\":\"$PLAN_CODE\"}")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$resp" ]]; then ok "subscriptions/checkout"; else bad "subscriptions/checkout" "$resp"; fi
else
  echo "SKIP: subscriptions/checkout (set RUN_CHECKOUT_CORE=true)"
fi

# Overage flows
set +e
resp=$(curl_get "/subscriptions/overage/items")
code=$?
set -e
if [[ $code -eq 0 && -n "$resp" ]]; then ok "overage/items"; else bad "overage/items" "$resp"; fi

set +e
resp=$(curl_get "/subscriptions/overage/credits")
code=$?
set -e
if [[ $code -eq 0 && -n "$resp" ]]; then ok "overage/credits"; else bad "overage/credits" "$resp"; fi

# Overage checkout — optional; run if ITEM_CODE provided
ITEM_CODE_ENV="${ITEM_CODE:-chat_unit}"
RUN_OVERAGE_CHECKOUT="${RUN_OVERAGE_CHECKOUT:-false}"
if [[ "$RUN_OVERAGE_CHECKOUT" == "true" ]]; then
  set +e
  resp=$(curl_post "/subscriptions/overage/checkout" "{\"code\":\"$ITEM_CODE_ENV\",\"quantity\":1}")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$resp" ]]; then ok "overage/checkout"; else bad "overage/checkout" "$resp"; fi
else
  echo "SKIP: overage/checkout (set RUN_OVERAGE_CHECKOUT=true)"
fi

# Legacy usage
set +e
resp=$(curl_get "/subscriptions/usage")
code=$?
set -e
if [[ $code -eq 0 && -n "$resp" ]]; then ok "subscriptions/usage (legacy)"; else bad "subscriptions/usage (legacy)" "$resp"; fi

# Reserve/commit/release (smoke only, does not mutate without follow-up)
set +e
resp=$(curl_post "/subscriptions/reserve-chat" '{}')
code=$?
set -e
if [[ $code -eq 0 && -n "$resp" ]]; then ok "reserve-chat"; else bad "reserve-chat" "$resp"; fi

set +e
resp=$(curl_post "/subscriptions/commit" '{"kind":"chat"}')
code=$?
set -e
if [[ $code -eq 0 && -n "$resp" ]]; then ok "commit"; else bad "commit" "$resp"; fi

set +e
resp=$(curl_post "/subscriptions/release" '{"kind":"chat"}')
code=$?
set -e
if [[ $code -eq 0 && -n "$resp" ]]; then ok "release"; else bad "release" "$resp"; fi

# Change/cancel/resume — skip by default, require explicit flags
RUN_CANCEL="${RUN_CANCEL:-false}"
RUN_RESUME="${RUN_RESUME:-false}"
RUN_CHANGE_PLAN="${RUN_CHANGE_PLAN:-false}"
CHANGE_TO_CODE="${CHANGE_TO_CODE:-premium}"

if [[ "$RUN_CANCEL" == "true" ]]; then
  set +e
  resp=$(curl_post "/subscriptions/cancel" '{}')
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$resp" ]]; then ok "cancel"; else bad "cancel" "$resp"; fi
else
  echo "SKIP: cancel (set RUN_CANCEL=true)"
fi

if [[ "$RUN_RESUME" == "true" ]]; then
  set +e
  resp=$(curl_post "/subscriptions/resume" '{}')
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$resp" ]]; then ok "resume"; else bad "resume" "$resp"; fi
else
  echo "SKIP: resume (set RUN_RESUME=true)"
fi

if [[ "$RUN_CHANGE_PLAN" == "true" ]]; then
  set +e
  resp=$(curl_post "/subscriptions/change-plan" "{\"code\":\"$CHANGE_TO_CODE\"}")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$resp" ]]; then ok "change-plan"; else bad "change-plan" "$resp"; fi
else
  echo "SKIP: change-plan (set RUN_CHANGE_PLAN=true)"
fi

# Portal checkout bridge
set +e
resp=$(curl_post "/subscriptions/stripe/checkout" '{}')
code=$?
set -e
if [[ $code -eq 0 && -n "$resp" ]]; then ok "subscriptions/stripe/checkout"; else bad "subscriptions/stripe/checkout" "$resp"; fi

# Admin overage surfaces (read-only + mutations) — optional flags
RUN_ADMIN_LISTS="${RUN_ADMIN_LISTS:-false}"
RUN_ADMIN_MARK_PAID="${RUN_ADMIN_MARK_PAID:-false}"
RUN_ADMIN_MARK_REFUNDED="${RUN_ADMIN_MARK_REFUNDED:-false}"
RUN_ADMIN_ADJUST_CREDITS="${RUN_ADMIN_ADJUST_CREDITS:-false}"
RUN_ADMIN_ITEMS="${RUN_ADMIN_ITEMS:-false}"
PURCHASE_ID_ENV="${PURCHASE_ID:-}"

if [[ "$RUN_ADMIN_LISTS" == "true" ]]; then
  set +e
  resp=$(curl_get "/subscriptions/admin/overage/purchases")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$resp" ]]; then ok "admin/overage/purchases"; else bad "admin/overage/purchases" "$resp"; fi

  set +e
  resp=$(curl_get "/subscriptions/admin/overage/consumptions")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$resp" ]]; then ok "admin/overage/consumptions"; else bad "admin/overage/consumptions" "$resp"; fi
else
  echo "SKIP: admin lists (set RUN_ADMIN_LISTS=true)"
fi

if [[ "$RUN_ADMIN_MARK_PAID" == "true" && -n "$PURCHASE_ID_ENV" ]]; then
  set +e
  resp=$(curl_post "/subscriptions/admin/overage/mark-paid" "{\"purchase_id\":\"$PURCHASE_ID_ENV\"}")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$resp" ]]; then ok "admin/overage/mark-paid"; else bad "admin/overage/mark-paid" "$resp"; fi
else
  echo "SKIP: mark-paid (set RUN_ADMIN_MARK_PAID=true and PURCHASE_ID)"
fi

if [[ "$RUN_ADMIN_MARK_REFUNDED" == "true" && -n "$PURCHASE_ID_ENV" ]]; then
  set +e
  resp=$(curl_post "/subscriptions/admin/overage/mark-refunded" "{\"purchase_id\":\"$PURCHASE_ID_ENV\"}")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$resp" ]]; then ok "admin/overage/mark-refunded"; else bad "admin/overage/mark-refunded" "$resp"; fi
else
  echo "SKIP: mark-refunded (set RUN_ADMIN_MARK_REFUNDED=true and PURCHASE_ID)"
fi

if [[ "$RUN_ADMIN_ADJUST_CREDITS" == "true" ]]; then
  set +e
  resp=$(curl_post "/subscriptions/admin/overage/adjust-credits" "{\"code\":\"$ITEM_CODE_ENV\",\"delta\":1}")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$resp" ]]; then ok "admin/overage/adjust-credits"; else bad "admin/overage/adjust-credits" "$resp"; fi
else
  echo "SKIP: adjust-credits (set RUN_ADMIN_ADJUST_CREDITS=true)"
fi

if [[ "$RUN_ADMIN_ITEMS" == "true" ]]; then
  set +e
  resp=$(curl_post "/subscriptions/admin/overage/items" "{\"code\":\"$ITEM_CODE_ENV\",\"name\":\"Chat Unit\",\"currency\":\"MXN\",\"price\":100}")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$resp" ]]; then ok "admin/overage/items (POST)"; else bad "admin/overage/items (POST)" "$resp"; fi

  set +e
  resp=$(curl_get "/subscriptions/admin/overage/items")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$resp" ]]; then ok "admin/overage/items (GET)"; else bad "admin/overage/items (GET)" "$resp"; fi
else
  echo "SKIP: admin items (set RUN_ADMIN_ITEMS=true)"
fi

echo "Summary: PASS=$pass FAIL=$fail"
if [[ $fail -gt 0 ]]; then
  exit 1
fi
