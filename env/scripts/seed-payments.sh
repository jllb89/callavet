#!/usr/bin/env bash
set -euo pipefail

# Seed sample payments & invoices for smoke testing.
# Usage:
#   set -a && source ./.env.staging && set +a
#   bash env/scripts/seed-payments.sh
# Optional: export SEED_USER_ID=<uuid> to force a user.

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "ERROR: DATABASE_URL not set (source .env.staging first)." >&2
  exit 1
fi

psql_exec() {
  local sql="$1"
  psql "$DATABASE_URL" -X -q -c "$sql"
}

# Resolve user id (first user) unless SEED_USER_ID provided
USER_ID=${SEED_USER_ID:-}
if [[ -z "$USER_ID" ]]; then
  USER_ID=$(psql "$DATABASE_URL" -t -A -c "select id from users order by created_at asc limit 1;") || true
fi
if [[ -z "$USER_ID" ]]; then
  echo "ERROR: no users found; create a user/session first." >&2
  exit 1
fi

echo "Using USER_ID=$USER_ID"

# Insert payments (skip if provider_payment_id already exists)
psql_exec "insert into payments (id,user_id,amount_cents,status,provider_payment_id,tax_rate) 
values (gen_random_uuid(),'$USER_ID',15000,'paid','seed_pay_1',0.16) on conflict (provider,provider_payment_id) do nothing;"
psql_exec "insert into payments (id,user_id,amount_cents,status,provider_payment_id,tax_rate) 
values (gen_random_uuid(),'$USER_ID',27500,'refunded','seed_pay_2',0.16) on conflict (provider,provider_payment_id) do nothing;"

# Insert invoices (skip if provider_invoice_id already exists)
psql_exec "insert into invoices (id,user_id,amount_cents,status,provider_invoice_id,tax_rate) 
values (gen_random_uuid(),'$USER_ID',15000,'paid','seed_inv_1',0.16) on conflict (provider,provider_invoice_id) do nothing;"
psql_exec "insert into invoices (id,user_id,amount_cents,status,provider_invoice_id,tax_rate) 
values (gen_random_uuid(),'$USER_ID',27500,'open','seed_inv_2',0.16) on conflict (provider,provider_invoice_id) do nothing;"

# Show counts
psql_exec "select count(*) as payments_count from payments;"
psql_exec "select count(*) as invoices_count from invoices;"

# Show recent rows (limit 2)
psql_exec "select id, amount_cents, status, created_at from payments order by created_at desc limit 2;"
psql_exec "select id, amount_cents, status, issued_at  from invoices order by issued_at desc limit 2;"

echo "Run smoke script to verify API:" >&2
echo "bash env/scripts/smoke-payments.sh" >&2
