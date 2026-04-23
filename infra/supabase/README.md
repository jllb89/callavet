# Supabase CLI workflow

This repo now has a native Supabase CLI project in `supabase/`.

Historical SQL remains in `packages/db/migrations/` because older files reuse version prefixes such as `0001` and `0017`, which cannot be mirrored directly into Supabase CLI history.

The current mirrored Supabase CLI range is `0035` through `0042`. Treat this as a recent-history bridge for CLI visibility, not a full bootstrap of the whole database archive.

Use these commands from the repo root when working against staging:

```bash
. env/scripts/export-staging.sh
supabase migration list --db-url "$SUPABASE_DIRECT_DATABASE_URL"
supabase migration repair 0041 --status applied --db-url "$SUPABASE_DIRECT_DATABASE_URL" --yes
supabase db push --dry-run --db-url "$SUPABASE_DIRECT_DATABASE_URL"
```

`DATABASE_URL` still points at the Supabase transaction pooler and remains fine for `psql`-based scripts. Supabase CLI migration commands should use `SUPABASE_DIRECT_DATABASE_URL`.

Workflow going forward:

- Keep the legacy archive in `packages/db/migrations/` for existing `psql`-based flows.
- Add Supabase-managed remote migrations in `supabase/migrations/<version>_<name>.sql`.
- Mirror a file into `packages/db/migrations/` only if the legacy apply script also needs to run it.
- `env/scripts/migrate-staging.sh` applies the legacy archive first, then any additional files in `supabase/migrations/`, skipping duplicate basenames.
