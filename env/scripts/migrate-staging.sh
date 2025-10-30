#!/usr/bin/env bash
set -euo pipefail

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required on the machine running this script" >&2
  exit 1
fi

: "${DATABASE_URL:?DATABASE_URL must be set (e.g., from Supabase)}"

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
MIG_DIR="$ROOT_DIR/packages/db/migrations"

export PGCONNECT_TIMEOUT=10

echo "Applying migrations to: ${DATABASE_URL%%@*}@***"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$MIG_DIR/0001_full_schema.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$MIG_DIR/0002_seed.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$MIG_DIR/0003_search_triggers.sql"

echo "Migrations applied successfully"
