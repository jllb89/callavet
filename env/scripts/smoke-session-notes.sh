#!/usr/bin/env zsh
set -euo pipefail

: ${GATEWAY_BASE:?"Set GATEWAY_BASE (e.g., https://api.staging.callavet.mx)"}
: ${TOKEN:?"Set TOKEN (Bearer JWT)"}
: ${SESSION_ID:?"Set SESSION_ID (chat_sessions.id)"}

hdr=(
  -H "Authorization: Bearer $TOKEN"
  -H "Content-Type: application/json"
)

print -- "[session-notes] Posting note to session=$SESSION_ID"
post_resp=$(curl -sS -X POST $hdr[@] \
  --data '{"summary_text":"Quick SOAP summary","plan_summary":"Hydration, rest, monitor appetite"}' \
  "$GATEWAY_BASE/sessions/$SESSION_ID/notes")
print -- "$post_resp" | jq . 2>/dev/null || print -- "$post_resp"

note_id=$(print -- $post_resp | jq -r '.id // empty' 2>/dev/null || true)
if [[ -z "$note_id" ]]; then
  print -- "[session-notes] POST failed; reason: $(print -- $post_resp | jq -r '.reason // "unknown"' 2>/dev/null)"
  exit 1
fi
print -- "[session-notes] Created note id=$note_id"

print -- "[session-notes] Listing notes for session=$SESSION_ID"
list_resp=$(curl -sS -X GET $hdr[@] "$GATEWAY_BASE/sessions/$SESSION_ID/notes")
print -- "$list_resp" | jq . 2>/dev/null || print -- "$list_resp"

count=$(print -- $list_resp | jq -r '.data | length' 2>/dev/null || echo 0)
print -- "[session-notes] Notes count=$count"

print -- "[session-notes] Smoke complete"
