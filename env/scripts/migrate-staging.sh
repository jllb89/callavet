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

echo "Running all migrations in $MIG_DIR"
for f in "$MIG_DIR"/0*.sql; do
  echo "Applying $(basename "$f")"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
done

echo "All migrations applied successfully"
