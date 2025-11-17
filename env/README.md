Centralized helpers for exporting per-environment variables.

Local database SSL

- When connecting to managed Postgres providers (like Supabase), TLS is often required and may use a custom CA. For local development we now default to skipping certificate verification unless a CA bundle is provided.
- Controls (in priority order):
	1) `DATABASE_SSL_CA_PATH` – absolute path to a PEM file. If set and exists, verification is enforced using this CA.
	2) `DATABASE_SSL_REJECT_UNAUTHORIZED` – set to `0` to disable verification. Any other value (or unset) will honor defaults below.
	3) `PGSSLMODE` – if set to `allow`, `prefer`, or `no-verify`, verification is disabled. Any other value has no effect.
	4) `NODE_ENV` – if not `production`, verification is disabled by default. In production, verification is enforced.

Tips

- For local dev with a self-signed DB cert, either set `PGSSLMODE=no-verify` or `DATABASE_SSL_REJECT_UNAUTHORIZED=0`.
- For CI/prod, either remove those flags or provide a CA via `DATABASE_SSL_CA_PATH`.
