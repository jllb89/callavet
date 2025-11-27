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
[[ $code -eq 0 ]] && echo "$resp" | $JQ -e '.items | type == "array"' >/dev/null 2>&1; assert_ok $? "kb list authed"

# 3) Create KB item
code=0
resp=$(curl -sS -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  -d '{"title":"Test KB","content":"First content","species":["dog"],"tags":["general"],"language":"en"}' \
  "$BASE/kb") || code=$?
kb_id=$(echo "$resp" | $JQ -r '.id // empty')
[[ -n "$kb_id" ]]; assert_ok $? "kb create"

# 4) Get KB item by id
code=0
resp=$(curl -sS -H "$AUTH_HEADER" "$BASE/kb/$kb_id") || code=$?
[[ $code -eq 0 ]] && echo "$resp" | $JQ -e '.title == "Test KB"' >/dev/null 2>&1; assert_ok $? "kb get"

# 5) Lexical search
code=0
resp=$(curl -sS -H "$AUTH_HEADER" "$BASE/search?type=kb&q=Test&limit=5") || code=$?
[[ $code -eq 0 ]] && echo "$resp" | $JQ -e '.items | type == "array" and (.took_ms | tonumber) >= 0' >/dev/null 2>&1; assert_ok $? "kb lexical search"

# 6) Vector search (GET variant) — minimal embedding
code=0
resp=$(curl -sS -H "$AUTH_HEADER" "$BASE/vector/search?target=kb&embedding=0.1,0.2,0.3&topK=3") || code=$?
[[ $code -eq 0 ]] && echo "$resp" | $JQ -e '.results | type == "array"' >/dev/null 2>&1; assert_ok $? "vector search get"

# 7) Vector search (POST)
code=0
resp=$(curl -sS -X POST -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  -d '{"target":"kb","query_embedding":[0.1,0.2,0.3],"topK":3}' \
  "$BASE/vector/search") || code=$?
[[ $code -eq 0 ]] && echo "$resp" | $JQ -e '.results | type == "array"' >/dev/null 2>&1; assert_ok $? "vector search post"

# Summary
echo "Summary: PASS=$pass FAIL=$fail"
exit $([[ $fail -eq 0 ]] && echo 0 || echo 1)
