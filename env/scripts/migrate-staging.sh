#!/usr/bin/env bash
set -euo pipefail

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required on the machine running this script" >&2
  exit 1
fi

: "${DATABASE_URL:?DATABASE_URL must be set (e.g., from Supabase)}"

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
LEGACY_MIG_DIR="$ROOT_DIR/packages/db/migrations"
SUPABASE_MIG_DIR="$ROOT_DIR/supabase/migrations"

export PGCONNECT_TIMEOUT=10
shopt -s nullglob

apply_dir() {
  local dir="$1"
  local label="$2"
  local found=0

  for f in "$dir"/*.sql; do
    local base
    base="$(basename "$f")"
    if [[ "$label" == "supabase" && -f "$LEGACY_MIG_DIR/$base" ]]; then
      echo "Skipping $base (already present in legacy archive)"
      continue
    fi

    found=1
    echo "Applying $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  done

  if [[ "$found" -eq 0 ]]; then
    echo "No SQL migrations found in $dir"
  fi
}

echo "Applying migrations to: ${DATABASE_URL%%@*}@***"

echo "Running legacy migrations in $LEGACY_MIG_DIR"
apply_dir "$LEGACY_MIG_DIR" legacy

if [[ -d "$SUPABASE_MIG_DIR" ]]; then
  echo "Running Supabase CLI migrations in $SUPABASE_MIG_DIR"
  apply_dir "$SUPABASE_MIG_DIR" supabase
fi

echo "All migrations applied successfully"
