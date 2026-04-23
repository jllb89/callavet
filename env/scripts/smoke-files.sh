#!/usr/bin/env zsh
set -euo pipefail

: ${GATEWAY_BASE:?"Set GATEWAY_BASE (e.g., https://api.staging.callavet.mx)"}
: ${TOKEN:?"Set TOKEN (Bearer JWT)"}
: ${PET_ID:=}

hdr=(
  -H "Authorization: Bearer $TOKEN"
  -H "Content-Type: application/json"
)

curl_bin=${CURL_BIN:-$(command -v curl || true)}
if [[ -z "$curl_bin" ]]; then
  if [[ -x /usr/bin/curl ]]; then
    curl_bin=/usr/bin/curl
  else
    print -- "ERROR: curl not found"
    exit 127
  fi
fi

jq_bin=${JQ_BIN:-$(command -v jq || true)}
if [[ -z "$jq_bin" && -x /usr/bin/jq ]]; then
  jq_bin=/usr/bin/jq
fi

if [[ -z "$PET_ID" ]]; then
  pets_resp=$($curl_bin -sS -H "Authorization: Bearer $TOKEN" "$GATEWAY_BASE/pets" || true)
  if [[ -n "$jq_bin" ]]; then
    PET_ID=$(echo "$pets_resp" | "$jq_bin" -r '.data[0].id // empty' 2>/dev/null || true)
  else
    PET_ID=$(echo "$pets_resp" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  fi
fi

if [[ -z "$PET_ID" ]]; then
  print -- "ERROR: PET_ID is required (set PET_ID or ensure /pets has at least one pet)"
  exit 1
fi

path="pets/$PET_ID/smoke-files/example.txt"
content_b64='aGVsbG8gZnJvbSBzbW9rZS1maWxlcw=='

print -- "[files] Upload"
up=$($curl_bin -sS -X POST $hdr[@] \
  --data "{\"path\":\"$path\",\"content\":\"$content_b64\",\"contentType\":\"text/plain\",\"petId\":\"$PET_ID\"}" \
  "$GATEWAY_BASE/files/upload")
if [[ -n "$jq_bin" ]]; then
  print -- "$up" | "$jq_bin" . 2>/dev/null || print -- "$up"
else
  print -- "$up"
fi

if [[ -n "$jq_bin" ]]; then
  ok=$(echo "$up" | "$jq_bin" -r '.ok // empty' 2>/dev/null || true)
else
  if [[ "$up" == *'"ok":true'* ]]; then
    ok=true
  else
    ok=''
  fi
fi
if [[ "$ok" != "true" ]]; then
  print -- "ERROR: upload failed"
  exit 1
fi

print -- "[files] Download URL"
dn=$($curl_bin -sS -H "Authorization: Bearer $TOKEN" "$GATEWAY_BASE/files/download-url?path=$path")
if [[ -n "$jq_bin" ]]; then
  print -- "$dn" | "$jq_bin" . 2>/dev/null || print -- "$dn"
else
  print -- "$dn"
fi

if [[ -n "$jq_bin" ]]; then
  url=$(echo "$dn" | "$jq_bin" -r '.url // empty' 2>/dev/null || true)
else
  url=$(echo "$dn" | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
fi
if [[ -z "$url" ]]; then
  print -- "ERROR: missing download URL"
  exit 1
fi

print -- "[files] Smoke complete"
