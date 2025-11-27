#!/usr/bin/env bash
set -euo pipefail

# Usage: set -a && source ./.env.staging && set +a; bash env/scripts/smoke-payments.sh
BASE="${GATEWAY_BASE:-${SERVER_URL:-}}"
AUTH_HEADER=${AUTH_HEADER:-"Authorization: Bearer ${SB_ACCESS_TOKEN:-}"}
JQ=${JQ:-jq}

pass=0; fail=0
assert_ok() { if [[ $1 -eq 0 ]]; then pass=$((pass+1)); echo "PASS: $2"; else fail=$((fail+1)); echo "FAIL: $2"; fi }

# Payments list
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "$AUTH_HEADER" "$BASE/payments" || echo 000)
resp=$(curl -sS -H "$AUTH_HEADER" "$BASE/payments" || true)
[[ "$code" == "200" ]] && echo "$resp" | $JQ -e '.data | type == "array"' >/dev/null 2>&1; assert_ok $? "payments list (code=$code)"

# If there is at least one payment, fetch detail
cnt=$(echo "$resp" | $JQ '.data | length')
if [[ "$cnt" -gt 0 ]]; then
  pid=$(echo "$resp" | $JQ -r '.data[0].id')
  d=$(curl -sS -H "$AUTH_HEADER" "$BASE/payments/$pid" || true)
  echo "$d" | $JQ -e '.id == '"$pid"'' >/dev/null 2>&1; assert_ok $? "payment detail"
else
  echo "INFO: no payments yet; skipping detail"
fi

# Invoices list
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "$AUTH_HEADER" "$BASE/invoices" || echo 000)
resp=$(curl -sS -H "$AUTH_HEADER" "$BASE/invoices" || true)
[[ "$code" == "200" ]] && echo "$resp" | $JQ -e '.data | type == "array"' >/dev/null 2>&1; assert_ok $? "invoices list (code=$code)"

# If there is at least one invoice, fetch detail
cnt=$(echo "$resp" | $JQ '.data | length')
if [[ "$cnt" -gt 0 ]]; then
  iid=$(echo "$resp" | $JQ -r '.data[0].id')
  d=$(curl -sS -H "$AUTH_HEADER" "$BASE/invoices/$iid" || true)
  echo "$d" | $JQ -e '.id == '"$iid"'' >/dev/null 2>&1; assert_ok $? "invoice detail"
else
  echo "INFO: no invoices yet; skipping detail"
fi

echo "Summary: PASS=$pass FAIL=$fail"
exit $([[ $fail -eq 0 ]] && echo 0 || echo 1)
