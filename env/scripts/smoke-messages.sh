#!/usr/bin/env bash
set -euo pipefail

# Smoke test: Messages (Group - session scoped + global)
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

# Create a session to attach messages to
set +e
resp=$(curl_post "/sessions/start" '{"kind":"chat"}')
code=$?
set -e
if [[ $code -ne 0 || -z "$resp" ]]; then bad "sessions start for messages" "$resp"; else ok "sessions start for messages"; fi

SESSION_ID=$(echo "$resp" | sed -n 's/.*"sessionId"\s*:\s*"\([^"]*\)".*/\1/p')
if command -v jq >/dev/null 2>&1; then SESSION_ID=$(echo "$resp" | jq -r '.sessionId // empty'); fi

if [[ -z "$SESSION_ID" ]]; then
  bad "parse sessionId" "$resp"
else
  # Session-scoped list
  set +e
  l=$(curl_get "/sessions/$SESSION_ID/messages")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$l" ]]; then ok "session messages list"; else bad "session messages list" "$l"; fi

  # Create message
  set +e
  c=$(curl_post "/sessions/$SESSION_ID/messages" '{"role":"user","content":"Hello from smoke"}')
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$c" ]]; then ok "session message create"; else bad "session message create" "$c"; fi

  # Parse created message id for global detail check
  if command -v jq >/dev/null 2>&1; then
    CREATED_MID=$(echo "$c" | jq -r '.message.id // .id // empty')
  else
    CREATED_MID=$(echo "$c" | sed -n 's/.*"id"\s*:\s*"\([^"]*\)".*/\1/p')
  fi
  if [[ -n "$CREATED_MID" ]]; then
    export MESSAGE_ID="$CREATED_MID"
  fi

  # Transcript
  set +e
  t=$(curl_get "/sessions/$SESSION_ID/transcript")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$t" ]]; then ok "session transcript"; else bad "session transcript" "$t"; fi
fi

# Global endpoints
set +e
gl=$(curl_get "/messages")
code=$?
set -e
if [[ $code -eq 0 && -n "$gl" ]]; then ok "messages list"; else bad "messages list" "$gl"; fi

# Filtered list (role=user) with pagination limit=5
set +e
glf=$(curl_get "/messages?role=user&limit=5")
code=$?
set -e
if [[ $code -eq 0 && -n "$glf" ]]; then ok "messages list filtered"; else bad "messages list filtered" "$glf"; fi

# Redact the created message then fetch detail
if [[ -n "${MESSAGE_ID:-}" ]]; then
  set +e
  red=$(curl -s -S -X PATCH -H "Authorization: Bearer ${SB_TOKEN}" -H "Content-Type: application/json" "${BASE_URL}/messages/${MESSAGE_ID}/redact" -d '{"reason":"smoke test"}')
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$red" && "$red" == *"[redacted]"* ]]; then ok "message redact"; else bad "message redact" "$red"; fi

  set +e
  det=$(curl_get "/messages/${MESSAGE_ID}")
  code=$?
  set -e
  if [[ $code -eq 0 && "$det" == *"[redacted]"* ]]; then ok "message detail after redact"; else bad "message detail after redact" "$det"; fi

  # Soft delete
  set +e
  del=$(curl -s -S -X DELETE -H "Authorization: Bearer ${SB_TOKEN}" "${BASE_URL}/messages/${MESSAGE_ID}")
  code=$?
  set -e
  if [[ $code -eq 0 && "$del" == *"[deleted]"* ]]; then ok "message soft delete"; else bad "message soft delete" "$del"; fi

  # Confirm list no longer shows message (since filter after deletion time)
  nowIso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  set +e
  lst=$(curl_get "/messages?since=${nowIso}") # should be empty list
  code=$?
  set -e
  if [[ $code -eq 0 ]]; then ok "messages since filter"; else bad "messages since filter" "$lst"; fi
fi

set +e
gt=$(curl_get "/messages/transcripts")
code=$?
set -e
if [[ $code -eq 0 && -n "$gt" ]]; then ok "messages transcripts"; else bad "messages transcripts" "$gt"; fi

# Detail requires MESSAGE_ID; skip unless provided
MID="${MESSAGE_ID:-}"
if [[ -n "$MID" ]]; then
  set +e
  gd=$(curl_get "/messages/$MID")
  code=$?
  set -e
  if [[ $code -eq 0 && -n "$gd" ]]; then ok "messages detail"; else bad "messages detail" "$gd"; fi
else
  echo "SKIP: messages detail (set MESSAGE_ID)"
fi

echo "Summary: PASS=$pass FAIL=$fail"
if [[ $fail -gt 0 ]]; then exit 1; fi
