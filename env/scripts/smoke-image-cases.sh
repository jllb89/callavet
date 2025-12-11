#!/usr/bin/env zsh
set -euo pipefail

: ${GATEWAY_BASE:?"Set GATEWAY_BASE"}
: ${TOKEN:?"Set TOKEN (Bearer JWT)"}
: ${PET_ID:?"Set PET_ID (uuid)"}
: ${SESSION_ID:=}

hdr=(
  -H "Authorization: Bearer $TOKEN"
  -H "Content-Type: application/json"
)

# Create a tiny PNG (1x1) base64 payload
# Precomputed transparent PNG
png_b64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII='
path="pets/$PET_ID/cases/smoke.png"

print -- "[image-cases] Uploading $path"
up=$(curl -sS -X POST "$GATEWAY_BASE/files/upload" $hdr[@] \
  -d "{\"path\":\"$path\",\"content\":\"$png_b64\",\"contentType\":\"image/png\",\"petId\":\"$PET_ID\",\"sessionId\":\"$SESSION_ID\"}")
print -- "$up" | jq . 2>/dev/null || print -- "$up"

print -- "[image-cases] Listing for pet $PET_ID"
ls=$(curl -sS -X GET "$GATEWAY_BASE/pets/$PET_ID/image-cases" -H "Authorization: Bearer $TOKEN")
print -- "$ls" | jq . 2>/dev/null || print -- "$ls"

print -- "[image-cases] Signed download URL"
url=$(curl -sS -X GET "$GATEWAY_BASE/files/download-url?path=$path" -H "Authorization: Bearer $TOKEN" | jq -r .url)
print -- "$url"

print -- "[image-cases] Fetching content (should be PNG)"
curl -sS "$url" | file -b - || print -- "downloaded"

print -- "[image-cases] Smoke complete"
