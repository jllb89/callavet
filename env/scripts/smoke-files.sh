#!/usr/bin/env zsh
set -euo pipefail

: ${GATEWAY_BASE:?"Set GATEWAY_BASE (e.g., https://api.staging.callavet.mx)"}
: ${TOKEN:?"Set TOKEN (Bearer JWT)"}

hdr=(
  -H "Authorization: Bearer $TOKEN"
  -H "Content-Type: application/json"
)

print -- "[files] Signed upload URL"
up=$(curl -sS -X POST $hdr[@] "$GATEWAY_BASE/files/signed-url")
print -- "$up" | jq . 2>/dev/null || print -- "$up"

print -- "[files] Download URL"
# optional path query
path="pets/$PET_ID/example.jpg"
 dn=$(curl -sS -X GET $hdr[@] "$GATEWAY_BASE/files/download-url?path=$path")
print -- "$dn" | jq . 2>/dev/null || print -- "$dn"

print -- "[files] Smoke complete"
