#!/usr/bin/env bash
set -euo pipefail

# Usage: set -a && source ./.env.staging && set +a; bash env/scripts/smoke-centers.sh
BASE="${GATEWAY_BASE:-${SERVER_URL:-}}"
JQ=${JQ:-jq}

pass=0; fail=0
assert_ok() { if [[ $1 -eq 0 ]]; then pass=$((pass+1)); echo "PASS: $2"; else fail=$((fail+1)); echo "FAIL: $2"; fi }

if [[ -z "${BASE}" ]]; then
  echo "FAIL: BASE URL not set. Source .env.staging first."; exit 1
fi

echo "Testing GET /centers/near ..."
status=$(curl -sS -o /tmp/resp_centers.json -w "%{http_code}" "${BASE}/centers/near?lat=19.4326&lng=-99.1332&radiusKm=50" || echo 000)
cat /tmp/resp_centers.json | ${JQ} '.' >/dev/null 2>&1 || true

# Accept both new (data[]) and legacy (centers[]) envelopes
key=$(${JQ} -r 'if (.data | type) == "array" then "data" else if (.centers | type) == "array" then "centers" else "none" end end' /tmp/resp_centers.json 2>/dev/null || echo none)
if [[ "$status" == "200" && "$key" != "none" ]]; then
  echo "PASS: centers near (200)"; pass=$((pass+1))
else
  echo "FAIL: centers near (status=$status key=$key)"; fail=$((fail+1))
fi

# Basic shape check: if items exist, ensure first has id and name
len=$(${JQ} ".${key} | length" /tmp/resp_centers.json 2>/dev/null || echo 0)
if [[ "$len" -gt 0 ]]; then
  id=$(${JQ} -r ".${key}[0].id" /tmp/resp_centers.json)
  name=$(${JQ} -r ".${key}[0].name" /tmp/resp_centers.json)
  if [[ "$id" != "null" && "$name" != "null" ]]; then
    echo "PASS: centers item shape (id,name)"; pass=$((pass+1))
  else
    echo "FAIL: centers item missing id/name"; fail=$((fail+1))
  fi
else
  echo "INFO: centers list empty; acceptable if no geo data"
fi

echo "Summary: PASS=$pass FAIL=$fail"
exit $([[ $fail -eq 0 ]] && echo 0 || echo 1)
