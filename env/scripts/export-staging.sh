#!/usr/bin/env bash

# This helper is meant to be sourced, so it must not modify the caller's shell options.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

export NODE_ENV=staging

if [[ -f "$ROOT_DIR/.env.staging" ]]; then
	set -a
	# shellcheck disable=SC1090
	source "$ROOT_DIR/.env.staging"
	set +a
fi

export VET_ID="${VET_ID:-00000000-0000-0000-0000-000000000003}"
export VET_USER_ID="${VET_USER_ID:-$VET_ID}"

if [[ -n "${DATABASE_URL:-}" ]] && command -v python3 >/dev/null 2>&1; then
	derived_direct_database_url="$({
		DATABASE_URL="$DATABASE_URL" python3 - <<'PY'
import os
from urllib.parse import urlsplit, urlunsplit

database_url = os.environ.get("DATABASE_URL", "")
if not database_url:
    raise SystemExit(0)

parsed = urlsplit(database_url)
hostname = parsed.hostname or ""
username = parsed.username or ""
password = parsed.password or ""

if hostname.endswith(".pooler.supabase.com") and username.startswith("postgres.") and password:
    project_ref = username.split(".", 1)[1]
    direct_host = f"db.{project_ref}.supabase.co"
    netloc = f"postgres:{password}@{direct_host}:5432"
    print(urlunsplit((parsed.scheme, netloc, parsed.path, parsed.query, parsed.fragment)))
else:
    print(database_url)
PY
	} 2>/dev/null)"

	if [[ -n "$derived_direct_database_url" ]]; then
		export SUPABASE_DIRECT_DATABASE_URL="$derived_direct_database_url"
	fi
fi
