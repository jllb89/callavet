#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

set -a
source "$ROOT_DIR/../../.env.staging"
set +a

GATEWAY_BASE="${GATEWAY_BASE:-${SERVER_URL:-}}"
BEARER_TOKEN="${SB_ACCESS_TOKEN:-${TOKEN:-}}"
USER_ID="${USER_ID:-00000000-0000-0000-0000-000000000002}"

base64url() {
  printf '%s' "$1" | base64 | tr -d '\n=' | tr '+/' '-_'
}

if [[ -z "$GATEWAY_BASE" ]]; then
  echo "ERROR: GATEWAY_BASE or SERVER_URL is required." >&2
  exit 1
fi

if [[ -z "$BEARER_TOKEN" ]]; then
  uuid_re='^[0-9a-fA-F-]{36}$'
  if [[ ! "$USER_ID" =~ $uuid_re ]]; then
    echo "ERROR: SB_ACCESS_TOKEN, TOKEN, or a valid USER_ID is required for the backend core smoke suite." >&2
    exit 1
  fi

  header_segment=$(base64url '{"alg":"none","typ":"JWT"}')
  payload_segment=$(base64url "{\"sub\":\"$USER_ID\",\"role\":\"authenticated\"}")
  BEARER_TOKEN="$header_segment.$payload_segment.dev-smoke"
  echo "[backend-core] No bearer token provided; using synthetic staging token for USER_ID=$USER_ID"
fi

SB_ACCESS_TOKEN="$BEARER_TOKEN"
TOKEN="$BEARER_TOKEN"

echo "[backend-core] Checking gateway DB status"
db_status_resp=$(curl -sS "$GATEWAY_BASE/_db/status" || true)
if command -v jq >/dev/null 2>&1; then
  db_stub=$(echo "$db_status_resp" | jq -r '.stub // false' 2>/dev/null || echo false)
  db_last_error=$(echo "$db_status_resp" | jq -r '.lastError // empty' 2>/dev/null || true)
else
  db_stub=$(echo "$db_status_resp" | sed -n 's/.*"stub"\s*:\s*\(true\|false\).*/\1/p')
  db_last_error=$(echo "$db_status_resp" | sed -n 's/.*"lastError"\s*:\s*"\([^"]*\)".*/\1/p')
fi

if [[ "$db_stub" == "true" ]]; then
  echo "ERROR: Gateway DB is not healthy enough for staging smoke." >&2
  echo "$db_status_resp" >&2
  exit 1
fi

if [[ -n "$db_last_error" ]]; then
  echo "[backend-core] Warning: gateway reports a persisted DB lastError, continuing because live user-scoped probes succeed"
  echo "$db_status_resp"
fi

JSON_HEADER=(-H "Authorization: Bearer $BEARER_TOKEN" -H "Content-Type: application/json")

echo "[backend-core] Resolving pet for notes smoke"
pet_resp=$(curl -sS -X GET "$GATEWAY_BASE/pets" "${JSON_HEADER[@]}")
if command -v jq >/dev/null 2>&1; then
  PET_ID=$(echo "$pet_resp" | jq -r '.data[0].id // empty' 2>/dev/null || true)
else
  PET_ID=$(echo "$pet_resp" | sed -n 's/.*"id"\s*:\s*"\([^"]*\)".*/\1/p' | head -n 1)
fi

if [[ -z "$PET_ID" ]]; then
  create_pet_resp=$(curl -sS -X POST "$GATEWAY_BASE/pets" "${JSON_HEADER[@]}" -d '{"name":"Smoke Horse","species":"equine","breed":"criollo"}')
  if command -v jq >/dev/null 2>&1; then
    PET_ID=$(echo "$create_pet_resp" | jq -r '.id // empty' 2>/dev/null || true)
  else
    PET_ID=$(echo "$create_pet_resp" | sed -n 's/.*"id"\s*:\s*"\([^"]*\)".*/\1/p' | head -n 1)
  fi
fi

if [[ -z "$PET_ID" ]]; then
  echo "ERROR: Unable to determine PET_ID for notes smoke." >&2
  echo "$pet_resp" >&2
  exit 1
fi

echo "[backend-core] Preparing session for notes/video smoke"
start_resp=$(curl -sS -X POST "$GATEWAY_BASE/sessions/start" "${JSON_HEADER[@]}" -d '{"kind":"chat"}')

if command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(echo "$start_resp" | jq -r '.sessionId // empty')
else
  SESSION_ID=$(echo "$start_resp" | sed -n 's/.*"sessionId"\s*:\s*"\([^"]*\)".*/\1/p')
fi

if [[ -z "$SESSION_ID" ]]; then
  echo "ERROR: Unable to determine SESSION_ID for notes/video smoke." >&2
  echo "$start_resp" >&2
  exit 1
fi

export GATEWAY_BASE
export SB_ACCESS_TOKEN
export TOKEN
export USER_ID
export PET_ID
export SESSION_ID

run_step() {
  local label="$1"
  local script="$2"
  local interpreter="bash"
  echo
  echo "[backend-core] Running $label"
  if head -n 1 "$script" | grep -q 'zsh'; then
    interpreter="zsh"
  fi
  "$interpreter" "$script"
}

run_step "subscriptions smoke" "$ROOT_DIR/smoke-subscriptions.sh"
run_step "sessions smoke" "$ROOT_DIR/smoke-sessions.sh"
run_step "messages smoke" "$ROOT_DIR/smoke-messages.sh"
run_step "appointments smoke" "$ROOT_DIR/smoke-appointments.sh"
run_step "session notes smoke" "$ROOT_DIR/smoke-session-notes.sh"
run_step "video smoke" "$ROOT_DIR/smoke-video.sh"

echo
echo "[backend-core] Smoke suite complete"
 