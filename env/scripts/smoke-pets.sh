#!/usr/bin/env bash
set -euo pipefail

# Usage: set -a && source ./.env.staging && set +a; bash env/scripts/smoke-pets.sh
BASE="${GATEWAY_BASE:-${SERVER_URL:-}}"
AUTH_HEADER=${AUTH_HEADER:-"Authorization: Bearer ${SB_ACCESS_TOKEN:-}"}
JQ=${JQ:-jq}

pass=0; fail=0
assert_ok() { if [[ $1 -eq 0 ]]; then pass=$((pass+1)); echo "PASS: $2"; else fail=$((fail+1)); echo "FAIL: $2"; fi }

# List pets
resp=$(curl -sS -H "$AUTH_HEADER" "$BASE/pets") || true
echo "$resp" | $JQ -e '.items | type == "array"' >/dev/null 2>&1; assert_ok $? "pets list"

# Create pet
resp=$(curl -sS -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  -d '{"name":"Fido","species":"dog","breed":"mix"}' \
  "$BASE/pets") || true
pet_id=$(echo "$resp" | $JQ -r '.id // empty')
[[ -n "$pet_id" ]]; assert_ok $? "pets create"

# Detail
resp=$(curl -sS -H "$AUTH_HEADER" "$BASE/pets/$pet_id") || true
echo "$resp" | $JQ -e '.id == "'$pet_id'"' >/dev/null 2>&1; assert_ok $? "pets detail"

# Patch
resp=$(curl -sS -X PATCH -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  -d '{"name":"Fido II"}' \
  "$BASE/pets/$pet_id") || true
echo "$resp" | $JQ -e '.name == "Fido II"' >/dev/null 2>&1; assert_ok $? "pets patch"

# Delete (archive)
resp=$(curl -sS -X DELETE -H "$AUTH_HEADER" "$BASE/pets/$pet_id") || true
echo "$resp" | $JQ -e '.ok == true' >/dev/null 2>&1; assert_ok $? "pets delete"

# Summary
echo "Summary: PASS=$pass FAIL=$fail"
exit $([[ $fail -eq 0 ]] && echo 0 || echo 1)
