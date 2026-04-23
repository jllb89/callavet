#!/usr/bin/env bash
set -euo pipefail

# Usage: set -a && source ./.env.staging && set +a; bash env/scripts/smoke-kb-search.sh
BASE="${GATEWAY_BASE:-${SERVER_URL:-}}"
AUTH_HEADER=${AUTH_HEADER:-"Authorization: Bearer ${SB_ACCESS_TOKEN:-}"}
JQ=${JQ:-jq}

pass=0; fail=0
assert_ok() { if [[ $1 -eq 0 ]]; then pass=$((pass+1)); echo "PASS: $2"; else fail=$((fail+1)); echo "FAIL: $2"; fi }

# 1) KB list (unauth) — treat 200 as PASS when public listing is enabled
http=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/kb" || echo "curl_error")
if [[ "$http" == "200" ]]; then
  echo "PASS: kb list unauth (public)"; pass=$((pass+1))
elif [[ "$http" == "401" ]]; then
  echo "PASS: kb list requires auth"; pass=$((pass+1))
else
  echo "FAIL: unexpected status for unauth kb list: $http"; fail=$((fail+1))
fi

# 2) KB list with auth
code=0
resp=$(curl -sS -H "$AUTH_HEADER" "$BASE/kb?limit=5") || code=$?
if [[ $code -eq 0 ]] && echo "$resp" | $JQ -e '.items | type == "array"' >/dev/null 2>&1; then
  assert_ok 0 "kb list authed"
else
  assert_ok 1 "kb list authed"
fi

# 3) Create KB item
code=0
resp=$(curl -sS -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  -d '{"title":"Test KB","content":"First content","species":["dog"],"tags":["general"],"language":"en"}' \
  "$BASE/kb") || code=$?
kb_id=$(echo "$resp" | $JQ -r '.id // empty')
if [[ -n "$kb_id" ]]; then
  assert_ok 0 "kb create"
else
  assert_ok 1 "kb create"
fi

# 4) Get KB item by id
code=0
resp=$(curl -sS -H "$AUTH_HEADER" "$BASE/kb/$kb_id") || code=$?
if [[ $code -eq 0 ]] && echo "$resp" | $JQ -e '.title == "Test KB"' >/dev/null 2>&1; then
  assert_ok 0 "kb get"
else
  assert_ok 1 "kb get"
fi

# 5) Lexical search
code=0
resp=$(curl -sS -H "$AUTH_HEADER" "$BASE/search?type=kb&q=Test&limit=5") || code=$?
if [[ $code -eq 0 ]] && echo "$resp" | $JQ -e '.items | type == "array"' >/dev/null 2>&1; then
  assert_ok 0 "kb lexical search"
else
  assert_ok 1 "kb lexical search"
fi

# 6) Vector search (GET variant) — minimal embedding
code=0
resp=$(curl -sS -H "$AUTH_HEADER" "$BASE/vector/search?target=kb&embedding=0.1,0.2,0.3&topK=3") || code=$?
if [[ $code -eq 0 ]] && echo "$resp" | $JQ -e '.results | type == "array"' >/dev/null 2>&1; then
  assert_ok 0 "vector search get"
else
  assert_ok 1 "vector search get"
fi

# 7) Vector search (POST)
code=0
resp=$(curl -sS -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  -d '{"target":"kb","query_embedding":[0.1,0.2,0.3],"topK":3}' \
  "$BASE/vector/search") || code=$?
if [[ $code -eq 0 ]] && echo "$resp" | $JQ -e '.results | type == "array"' >/dev/null 2>&1; then
  assert_ok 0 "vector search post"
else
  assert_ok 1 "vector search post"
fi

# Summary
echo "Summary: PASS=$pass FAIL=$fail"
exit $([[ $fail -eq 0 ]] && echo 0 || echo 1)
