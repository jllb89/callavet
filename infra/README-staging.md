# Staging deployment

This repo ships a simple Docker Compose stack for staging.

## Images

CI builds and pushes images to GHCR (GitHub Container Registry):
- ghcr.io/<OWNER>/cav-gateway:staging
- ghcr.io/<OWNER>/cav-webhooks:staging
- ghcr.io/<OWNER>/cav-chat:staging

It also publishes content-addressable tags: `:staging-<sha>`.

## Prereqs
- A VM with Docker + Docker Compose
- Access to pull from GHCR (docker login ghcr.io)
- A Supabase project (staging) and its `DATABASE_URL` and `SUPABASE_JWT_SECRET`

## Quick start

1) Copy env/.env.staging.example to the VM and export (or use a proper secret store):

```bash
export $(cat env/.env.staging.example | xargs)
```

2) Create the Supabase project and run migrations (once):

```bash
# Ensure DATABASE_URL is set in your env first (sslmode=require)
env/scripts/migrate-staging.sh
```

3) Pull and run:

```bash
cd infra
# ensure REGISTRY_OWNER is exported (e.g., your GitHub org/user)
export REGISTRY_OWNER=my-org
export TAG=staging # or staging-<sha>

docker compose -f docker-compose.staging.yml pull || true
# First run will pull on-demand if not present

docker compose -f docker-compose.staging.yml up -d
```

4) Verify:

```bash
curl -sS http://<vm-ip>:4000/health
curl -sS http://<vm-ip>:4000/openapi.yaml | head
curl -sS -X POST http://<vm-ip>:4000/sessions/start \
  -H 'content-type: application/json' \
  -H 'x-user-id: 00000000-0000-0000-0000-000000000002' \
  -d '{"kind":"chat"}'
```

## Reverse proxy (optional)
Put a TLS proxy in front and map `staging.call-a-vet.app` to gateway:4000. Keep `chat` and `webhooks` internal unless you need direct access.

Example Caddyfile (infra/caddy/Caddyfile):

```
staging.call-a-vet.app {
  encode gzip
  reverse_proxy 127.0.0.1:4000
}
```

## Roll forward/back
- Redeploy latest: set `TAG=staging` and `docker compose up -d`
- Pin to a commit: set `TAG=staging-<sha>` and `docker compose up -d`
