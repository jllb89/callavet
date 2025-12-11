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

# Resolve required binaries to avoid PATH issues
curl_bin=${CURL_BIN:-$(command -v curl || true)}
jq_bin=${JQ_BIN:-$(command -v jq || true)}
file_bin=${FILE_BIN:-$(command -v file || true)}
if [[ -z "$curl_bin" ]]; then
  if [[ -x /usr/bin/curl ]]; then curl_bin=/usr/bin/curl; else
    print -- "ERROR: curl not found. Install curl or set CURL_BIN." >&2
    exit 127
  fi
fi
[[ -z "$jq_bin" ]] && jq_bin=/usr/bin/jq
[[ -z "$file_bin" ]] && file_bin=/usr/bin/file

# Create a tiny PNG (1x1) base64 payload
# Precomputed transparent PNG
png_b64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII='
path="pets/$PET_ID/cases/smoke.png"

print -- "[image-cases] Uploading $path"
up=$($curl_bin -sS -X POST "$GATEWAY_BASE/files/upload" $hdr[@] \
  -d "{\"path\":\"$path\",\"content\":\"$png_b64\",\"contentType\":\"image/png\",\"petId\":\"$PET_ID\",\"sessionId\":\"$SESSION_ID\"}")
if [[ -n "$jq_bin" && -x "$jq_bin" ]]; then
  print -- "$up" | "$jq_bin" . 2>/dev/null || print -- "$up"
else
  print -- "$up"
fi

print -- "[image-cases] Listing for pet $PET_ID"
ls=$($curl_bin -sS -X GET "$GATEWAY_BASE/pets/$PET_ID/image-cases" -H "Authorization: Bearer $TOKEN")
if [[ -n "$jq_bin" && -x "$jq_bin" ]]; then
  print -- "$ls" | "$jq_bin" . 2>/dev/null || print -- "$ls"
else
  print -- "$ls"
fi

print -- "[image-cases] Signed download URL"
url=$($curl_bin -sS -X GET "$GATEWAY_BASE/files/download-url?path=$path" -H "Authorization: Bearer $TOKEN" | ${jq_bin:-jq} -r .url 2>/dev/null || true)
print -- "$url"

print -- "[image-cases] Fetching content (should be PNG)"
$curl_bin -sS "$url" | "$file_bin" -b - || print -- "downloaded"

print -- "[image-cases] Smoke complete"
