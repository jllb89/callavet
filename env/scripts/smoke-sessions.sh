#!/usr/bin/env bash
set -euo pipefail

# Smoke test: Sessions (Group 4)
# Source .env.staging for environment
set -a
source "$(dirname "$0")/../../.env.staging"
set +a

BASE_URL="${GATEWAY_BASE:-$SERVER_URL}"
SB_TOKEN="${SB_ACCESS_TOKEN:-}"
AUTH_HEADER="Authorization: Bearer ${SB_TOKEN}"
JSON_HEADER=("-H" "Content-Type: application/json")

pass=0
fail=0

ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; echo "$2"; fail=$((fail+1)); }

curl_get(){
  local path="$1"
  local hdrs=("-H" "Accept: application/json")
  if [[ -n "$SB_TOKEN" ]]; then hdrs+=("-H" "$AUTH_HEADER"); fi
  curl -s -S -X GET "${BASE_URL}${path}" "${hdrs[@]}"
}

curl_post(){
  local path="$1"; shift
  local body="$1"; shift
  local hdrs=("-H" "Accept: application/json" "${JSON_HEADER[@]}")
  if [[ -n "$SB_TOKEN" ]]; then hdrs+=("-H" "$AUTH_HEADER"); fi
  curl -s -S -X POST "${BASE_URL}${path}" "${hdrs[@]}" -d "$body"
}

curl_patch(){
  local path="$1"; shift
  local body="$1"; shift
  local hdrs=("-H" "Accept: application/json" "${JSON_HEADER[@]}")
  if [[ -n "$SB_TOKEN" ]]; then hdrs+=("-H" "$AUTH_HEADER"); fi
  curl -s -S -X PATCH "${BASE_URL}${path}" "${hdrs[@]}" -d "$body"
}

# List
set +e
resp=$(curl_get "/sessions?limit=5&offset=0")
code=$?
set -e
if [[ $code -eq 0 && -n "$resp" ]]; then ok "sessions list"; else bad "sessions list" "$resp"; fi

# Start a chat session
set +e
resp=$(curl_post "/sessions/start" '{"kind":"chat"}')
code=$?
set -e
if [[ $code -eq 0 && -n "$resp" ]]; then ok "sessions start chat"; else bad "sessions start chat" "$resp"; fi

# Extract sessionId and optional consumptionId
# Extract sessionId and optional consumptionId (robust JSON parsing via jq if available)
if command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(echo "$resp" | jq -r '.sessionId // empty')
  CONSUMPTION_ID=$(echo "$resp" | jq -r '.consumptionId // empty')
else
  SESSION_ID=$(echo "$resp" | sed -n 's/.*"sessionId"\s*:\s*"\([^"]*\)".*/\1/p')
  CONSUMPTION_ID=$(echo "$resp" | sed -n 's/.*"consumptionId"\s*:\s*"\([^"]*\)".*/\1/p')
fi

if [[ -z "$SESSION_ID" ]]; then
  # Fallback: derive latest session id from list response
  if command -v jq >/dev/null 2>&1; then
    SESSION_ID=$(echo "$resp" | jq -r '.sessionId // empty')
    if [[ -z "$SESSION_ID" ]]; then
      # try listing again and pick first id
      list=$(curl_get "/sessions?limit=1&offset=0")
      SESSION_ID=$(echo "$list" | jq -r '.data[0].id // empty')
    fi
  else
    # As a last resort, try a naive extraction from list
    list=$(curl_get "/sessions?limit=1&offset=0")
    SESSION_ID=$(echo "$list" | sed -n 's/.*"id"\s*:\s*"\([^\"]*\)".*/\1/p')
  fi
fi

if [[ -n "$SESSION_ID" ]]; then
  # Detail
  set +e
  d=$(curl_get "/sessions/$SESSION_ID")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$d" ]]; then ok "sessions detail"; else bad "sessions detail" "$d"; fi

  # Patch to completed
  set +e
  p=$(curl_patch "/sessions/$SESSION_ID" '{"status":"completed"}')
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$p" ]]; then ok "sessions patch completed"; else bad "sessions patch completed" "$p"; fi

  # End session (commit consumption if present)
  body='{"sessionId":"'"$SESSION_ID"'"'
  if [[ -n "$CONSUMPTION_ID" ]]; then body+=',"consumptionId":"'"$CONSUMPTION_ID"'"'; fi
  body+='}'
  set +e
  e=$(curl_post "/sessions/end" "$body")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$e" ]]; then ok "sessions end"; else bad "sessions end" "$e"; fi
else
  echo "FAIL: could not determine sessionId from start or list"
  echo "Start response:" "$resp"
  echo "List response:" "$list"
  fail=$((fail+1))
fi

echo "Summary: PASS=$pass FAIL=$fail"
if [[ $fail -gt 0 ]]; then exit 1; fi
