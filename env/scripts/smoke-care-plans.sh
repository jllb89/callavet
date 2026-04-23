#!/usr/bin/env bash
set -euo pipefail

# Usage: set -a && source ./.env.staging && set +a; bash env/scripts/smoke-care-plans.sh
BASE="${GATEWAY_BASE:-${SERVER_URL:-}}"
AUTH_HEADER=${AUTH_HEADER:-"Authorization: Bearer ${SB_ACCESS_TOKEN:-}"}
JQ=${JQ:-jq}

pass=0; fail=0
assert_ok() { if [[ $1 -eq 0 ]]; then pass=$((pass+1)); echo "PASS: $2"; else fail=$((fail+1)); echo "FAIL: $2"; fi }
assert_expr() {
  local label="$1"
  shift
  if "$@"; then
    assert_ok 0 "$label"
  else
    assert_ok 1 "$label"
  fi
}

# Resolve a session and pet for testing (minimal helpers via DB)
if [[ -z "${DATABASE_URL:-}" ]]; then echo "WARN: DATABASE_URL not set; some checks may be skipped"; fi
PET_ID=${PET_ID:-}
SESSION_ID=${SESSION_ID:-}
USER_ID=${USER_ID:-}
if [[ -z "$USER_ID" && -n "${DATABASE_URL:-}" ]]; then
  USER_ID=$(psql "$DATABASE_URL" -t -A -c "select id from users order by created_at asc limit 1;") || true
fi
if [[ -z "$PET_ID" && -n "${DATABASE_URL:-}" ]]; then
  PET_ID=$(psql "$DATABASE_URL" -t -A -c "select id from pets where user_id='$USER_ID' order by created_at desc limit 1;") || true
fi
if [[ -z "$PET_ID" && -n "${DATABASE_URL:-}" ]]; then
  # Seed a pet for this user if none exists
  psql "$DATABASE_URL" -c "insert into pets (id,user_id,name,species,created_at) values (gen_random_uuid(),'$USER_ID','Testy','dog',now());" >/dev/null || true
  PET_ID=$(psql "$DATABASE_URL" -t -A -c "select id from pets where user_id='$USER_ID' order by created_at desc limit 1;") || true
fi
if [[ -z "$SESSION_ID" && -n "${DATABASE_URL:-}" ]]; then
  SESSION_ID=$(psql "$DATABASE_URL" -t -A -c "select id from chat_sessions where user_id='$USER_ID' order by created_at desc limit 1;") || true
fi
if [[ -z "$SESSION_ID" && -n "${DATABASE_URL:-}" ]]; then
  # Seed a chat session for this user if none exists
  psql "$DATABASE_URL" -c "insert into chat_sessions (id,user_id,status,started_at,created_at) values (gen_random_uuid(),'$USER_ID','active',now(),now());" >/dev/null || true
  SESSION_ID=$(psql "$DATABASE_URL" -t -A -c "select id from chat_sessions where user_id='$USER_ID' order by created_at desc limit 1;") || true
fi

# Fallback to x-user-id header if bearer missing
if [[ -z "${SB_ACCESS_TOKEN:-}" && -n "${USER_ID:-}" ]]; then
  AUTH_HEADER="x-user-id: $USER_ID"
fi

# Notes list
echo "INFO: Using USER_ID=${USER_ID:-} PET_ID=${PET_ID:-} SESSION_ID=${SESSION_ID:-} BASE=$BASE"
notes_url="$BASE/sessions/$SESSION_ID/notes"
echo "INFO: notes_url=$notes_url"
if [[ -z "$SESSION_ID" ]]; then
  echo "FAIL: notes list (no SESSION_ID)"; fail=$((fail+1))
else
  code=$(curl -sS -o /dev/null -w '%{http_code}' -H "$AUTH_HEADER" "$notes_url" || echo 000)
  resp=$(curl -sS -H "$AUTH_HEADER" "$notes_url" || true)
  if [[ "$code" == "200" ]] && echo "$resp" | $JQ -e '.data | type == "array"' >/dev/null 2>&1; then
    assert_ok 0 "notes list (code=$code)"
  else
    assert_ok 1 "notes list (code=$code)"
  fi
fi

# Create note
if [[ -n "$SESSION_ID" ]]; then
  if [[ -n "$PET_ID" ]]; then
    note_payload=$(printf '{"summary_text":"Checkup summary","plan_summary":"Short plan","pet_id":"%s"}' "$PET_ID")
  else
    note_payload='{"summary_text":"Checkup summary","plan_summary":"Short plan"}'
  fi
  create=$(curl -sS -H "$AUTH_HEADER" -H 'Content-Type: application/json' -d "$note_payload" "$BASE/sessions/$SESSION_ID/notes" || true)
  if echo "$create" | $JQ -e '.id and .session_id' >/dev/null 2>&1; then
    assert_ok 0 "notes create"
  else
    assert_ok 1 "notes create"
  fi
else
  echo "INFO: skipping notes create (no SESSION_ID)"
fi

# Care plans list
if [[ -z "$PET_ID" ]]; then
  echo "FAIL: care plans list (no PET_ID)"; fail=$((fail+1))
else
  code=$(curl -sS -o /dev/null -w '%{http_code}' -H "$AUTH_HEADER" "$BASE/pets/$PET_ID/care-plans" || echo 000)
  resp=$(curl -sS -H "$AUTH_HEADER" "$BASE/pets/$PET_ID/care-plans" || true)
  if [[ "$code" == "200" ]] && echo "$resp" | $JQ -e '.data | type == "array"' >/dev/null 2>&1; then
    assert_ok 0 "care plans list (code=$code)"
  else
    assert_ok 1 "care plans list (code=$code)"
  fi
fi

# Create care plan
if [[ -n "$PET_ID" ]]; then
  create=$(curl -sS -H "$AUTH_HEADER" -H 'Content-Type: application/json' -d '{"short_term":"Hydration","mid_term":"Diet","long_term":"Exercise"}' "$BASE/pets/$PET_ID/care-plans" || true)
  if echo "$create" | $JQ -e '.id and .pet_id' >/dev/null 2>&1; then
    assert_ok 0 "care plan create"
  else
    assert_ok 1 "care plan create"
  fi
else
  echo "INFO: skipping care plan create (no PET_ID)"
fi

# List items for created plan (will be empty unless preseeded)
plan_id=$(echo "$create" | $JQ -r '.id // empty')
items='{"data":[]}'
if [[ -n "$plan_id" ]]; then
  items=$(curl -sS -H "$AUTH_HEADER" "$BASE/care-plans/$plan_id/items" || true)
  if echo "$items" | $JQ -e '.data | type == "array"' >/dev/null 2>&1; then
    assert_ok 0 "care plan items list"
  else
    assert_ok 1 "care plan items list"
  fi
else
  assert_ok 1 "care plan items list (missing plan id)"
fi

# Patch item (skip if none)
cnt=$(echo "$items" | $JQ '.data | length')
if [[ "$cnt" -gt 0 ]]; then
  iid=$(echo "$items" | $JQ -r '.data[0].id')
  patched=$(curl -sS -X PATCH -H "$AUTH_HEADER" -H 'Content-Type: application/json' -d '{"fulfilled":true}' "$BASE/care-plans/items/$iid" || true)
  if echo "$patched" | $JQ -e '.id == '"$iid"'' >/dev/null 2>&1; then
    assert_ok 0 "care plan item patch"
  else
    assert_ok 1 "care plan item patch"
  fi
else
  echo "INFO: no items to patch; skipping"
fi

echo "Summary: PASS=$pass FAIL=$fail"
exit $([[ $fail -eq 0 ]] && echo 0 || echo 1)
