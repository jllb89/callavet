#!/usr/bin/env bash
set -euo pipefail

# Usage: set -a && source ./.env.staging && set +a; bash env/scripts/smoke-pets.sh
BASE="${GATEWAY_BASE:-${SERVER_URL:-}}"
AUTH_HEADER=${AUTH_HEADER:-"Authorization: Bearer ${SB_ACCESS_TOKEN:-}"}
JQ=${JQ:-jq}

pass=0; fail=0
assert_ok() { if [[ $1 -eq 0 ]]; then pass=$((pass+1)); echo "PASS: $2"; else fail=$((fail+1)); echo "FAIL: $2"; fi }

# List pets
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "$AUTH_HEADER" "$BASE/pets" || echo 000)
resp=$(curl -sS -H "$AUTH_HEADER" "$BASE/pets" || true)
echo "$resp" | $JQ -e '.data | type == "array"' >/dev/null 2>&1; assert_ok $? "pets list (code=$code)"

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
del_code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "$AUTH_HEADER" "$BASE/pets/$pet_id" || echo 000)
if [[ "$del_code" == "204" ]]; then pass=$((pass+1)); echo "PASS: pets delete (204)"; else fail=$((fail+1)); echo "FAIL: pets delete (expected 204 got $del_code)"; fi

# Signed URL
resp=$(curl -sS -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  -d '{"path":"pets/'"$pet_id"'/test.txt"}' \
  "$BASE/pets/$pet_id/files/signed-url") || true
echo "$resp" | $JQ -e '.url | length > 0' >/dev/null 2>&1; assert_ok $? "pets signed-url"

# Summary
echo "Summary: PASS=$pass FAIL=$fail"
exit $([[ $fail -eq 0 ]] && echo 0 || echo 1)
