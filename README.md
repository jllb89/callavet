# Call a Vet - Monorepo

## Getting Started (Dev)

1. Install Node 18/20 and enable Corepack
2. Install dependencies

```bash
corepack enable
pnpm install
```

3. Start web app
```bash
pnpm dev:web
```

4. Start services (Docker)
```bash
# set envs in your shell or .env file (compose will read your shell env)
export DATABASE_URL=postgres://USER:PASS@HOST:5432/db_dev
export SUPABASE_JWT_SECRET=dev_supabase_jwt
export STRIPE_SECRET_KEY=sk_test_...
export STRIPE_WEBHOOK_SECRET=whsec_...

pnpm dev:services
```

5. Admin app
```bash
pnpm dev:admin
```

## Database

Run migrations and seed (echoed commands):
```bash
pnpm --filter @cav/db run migrate:dev
pnpm --filter @cav/db run seed:dev
```
Then execute the printed psql commands with your $DATABASE_URL.

## Smoke Tests

Reserve Chat (Gateway):
```bash
curl -s -X POST http://localhost:4000/subscriptions/reserve-chat \
  -H 'content-type: application/json' \
  -d '{"userId":"00000000-0000-0000-0000-000000000000","sessionId":"sess_123"}'
```
Start Session:
```bash
curl -s -X POST http://localhost:4000/sessions/start \
  -H 'content-type: application/json' \
  -d '{"kind":"chat","userId":"00000000-0000-0000-0000-000000000000"}'
```
Webhooks health:
```bash
curl -s http://localhost:4200/health
```

## Notes
- Gateway runs on :4000, Chat WS on :4100, Webhooks on :4200 by default.
- Web app proxies API calls to the Gateway via NEXT_PUBLIC_GATEWAY_URL (defaults to http://localhost:4000).
- Replace minimal SQL stubs with the full schema as needed.
