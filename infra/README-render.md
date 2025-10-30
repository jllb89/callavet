# Render deployment (staging)

This repo includes a `render.yaml` to deploy 3 services on Render:
- cav-gateway-staging (gateway API)
- cav-webhooks-staging (Stripe/webhooks)
- cav-chat-staging (chat service)

## Prereqs
- Render account connected to GitHub
- Repo: jllb89/callavet
- Region: `ohio` (closest to Supabase us-east-2)

## Deploy
1) In Render, create a new Blueprint from this repo (it will pick up `render.yaml`).
2) Set environment variables per service when prompted:
   - cav-gateway-staging:
     - NODE_ENV=staging
     - DATABASE_URL=postgresql://postgres:cKnwH7tGnW%2FzED6@db.oajnhvizipicnypdxcrb.supabase.co:5432/postgres?sslmode=require
     - SUPABASE_JWT_SECRET=2TcKeAd4SL6j4SK4oj7HG4LdrptLPeTfRV2vKSO2IVsi/N3iAYHzxJO5X/Tnb2CesDX9tOz2qulypjxjskXdHg==
     - STRIPE_SECRET_KEY= (optional)
   - cav-webhooks-staging:
     - NODE_ENV=staging
     - STRIPE_SECRET_KEY=
     - STRIPE_WEBHOOK_SECRET=
   - cav-chat-staging:
     - NODE_ENV=staging

3) Click Apply / Deploy. Render will build from the Dockerfiles and start services.

## Custom domain
- Open cav-gateway-staging → Settings → Custom domains → Add `staging.call-a-vet.app`
- Render gives you a CNAME target like `cav-gateway-staging.onrender.com`
- In your DNS for `call-a-vet.app`, add:
  - CNAME staging → cav-gateway-staging.onrender.com
- Wait for DNS and cert to provision.

## Health & smoke
- Health: https://staging.call-a-vet.app/health
- OpenAPI: https://staging.call-a-vet.app/openapi.yaml
- Start session (dev header override):

```bash
curl -sS -X POST https://staging.call-a-vet.app/sessions/start \
  -H 'content-type: application/json' \
  -H 'x-user-id: 00000000-0000-0000-0000-000000000002' \
  -d '{"kind":"chat"}'
```

Notes
- Render sets PORT and expects the app to bind to it. Gateway and services read PORT if present.
- For private Stripe keys, store them as Render environment variables (not in repo).
- Auto-deploy on push to `main` is enabled via render.yaml (autoDeploy: true).
