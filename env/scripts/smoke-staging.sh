#!/usr/bin/env bash
set -euo pipefail

API_BASE=${API_BASE:-http://localhost:4000}
USER_ID=${USER_ID:-00000000-0000-0000-0000-000000000002}

curl -f -sS "$API_BASE/health" | jq . || true

curl -f -sS "$API_BASE/openapi.yaml" | head -n 10 || true

curl -f -sS -X POST "$API_BASE/sessions/start" \
  -H 'content-type: application/json' \
  -H "x-user-id: $USER_ID" \
  -d '{"kind":"chat"}' | jq . || true

echo "Smoke tests finished"
