#!/usr/bin/env bash
set -euo pipefail

# ---------- helpers ----------
say() { printf "\n\033[1;36m➤ %s\033[0m\n" "$*"; }
# accept one or more dir paths
ensure_dir() { for d in "$@"; do [ -d "$d" ] || mkdir -p "$d"; done; }
ensure_file() { [ -f "$1" ] || touch "$1"; }

ROOT_DIR="$(pwd)"

say "1) Ensuring corepack/pnpm & turbo"
if ! command -v corepack >/dev/null 2>&1; then
  say "corepack not found. Install Node.js 18+/20+ first."
  exit 1
fi
corepack enable
corepack prepare pnpm@9.12.0 --activate

# ---------- root skeleton ----------
say "2) Scaffolding monorepo skeleton"
ensure_file package.json
if ! grep -q '"turbo"' package.json 2>/dev/null; then
  cat > package.json << 'JSON'
{
  "name": "call-a-vet",
  "private": true,
  "packageManager": "pnpm@9.12.0",
  "scripts": {
    "dev": "turbo run dev --parallel",
    "build": "turbo run build",
    "lint": "turbo run lint",
    "typecheck": "turbo run typecheck"
  },
  "devDependencies": {
    "turbo": "^2.1.3"
  }
}
JSON
fi

ensure_file pnpm-workspace.yaml
if ! grep -q 'apps/\*' pnpm-workspace.yaml 2>/dev/null; then
  cat > pnpm-workspace.yaml << 'YAML'
packages:
  - apps/*
  - services/*
  - packages/*
YAML
fi

ensure_file turbo.json
if ! grep -q '"pipeline"' turbo.json 2>/dev/null; then
  cat > turbo.json << 'JSON'
{
  "$schema": "https://turbo.build/schema.json",
  "pipeline": {
    "dev": { "cache": false, "persistent": true },
    "build": { "dependsOn": ["^build"], "outputs": ["dist/**", ".next/**", "build/**"] },
    "lint": {},
    "typecheck": {}
  }
}
JSON
fi

# editorconfig & gitignore
[ -f .editorconfig ] || cat > .editorconfig << 'TXT'
root = true
[*]
charset = utf-8
end_of_line = lf
indent_style = space
indent_size = 2
insert_final_newline = true
TXT

[ -f .gitignore ] || cat > .gitignore << 'TXT'
node_modules
.pnpm-store
dist
build
.next
*.log
.env*
!.env.example
.DS_Store
**/build
**/.dart_tool
**/.flutter-plugins
**/.flutter-plugins-dependencies
**/.packages
TXT

# env helpers
ensure_dir env/scripts
[ -f env/README.md ] || cat > env/README.md << 'MD'
Centralized helpers for exporting per-environment variables.
MD
[ -f env/scripts/export-dev.sh ] || cat > env/scripts/export-dev.sh << 'SH'
#!/usr/bin/env bash
export NODE_ENV=development
SH
[ -f env/scripts/export-staging.sh ] || cat > env/scripts/export-staging.sh << 'SH'
#!/usr/bin/env bash
export NODE_ENV=staging
SH
[ -f env/scripts/export-prod.sh ] || cat > env/scripts/export-prod.sh << 'SH'
#!/usr/bin/env bash
export NODE_ENV=production
SH
chmod +x env/scripts/*.sh || true

# ---------- apps ----------
say "3) Creating apps (web blended + admin)"
ensure_dir apps
pushd apps >/dev/null

# web (blended marketing + user)
if [ ! -d "web" ]; then
  pnpm dlx create-next-app@latest web --use-pnpm --typescript --eslint --app --tailwind --import-alias "@/*" --yes
fi

# admin
if [ ! -d "admin" ]; then
  pnpm dlx create-next-app@latest admin --use-pnpm --typescript --eslint --app --tailwind --import-alias "@/*" --yes
fi

popd >/dev/null

# ---------- web extra structure ----------
say "4) Scaffolding web extra structure"
ensure_dir 'apps/web/lib'
ensure_dir 'apps/web/components'
ensure_dir 'apps/web/i18n'
ensure_dir 'apps/web/app/(marketing)'
ensure_dir 'apps/web/app/(app)'
ensure_dir 'apps/web/app/(marketing)/pricing'
ensure_dir 'apps/web/app/(marketing)/kb'
ensure_dir 'apps/web/app/(marketing)/centers'
ensure_dir 'apps/web/app/(marketing)/apply-vet'
ensure_dir 'apps/web/app/(app)/start'
ensure_dir 'apps/web/app/(app)/patients'
ensure_dir 'apps/web/app/(app)/subscription'
ensure_dir 'apps/web/app/(app)/chat/[sessionId]'
ensure_dir 'apps/web/app/(app)/video/[roomId]'
ensure_dir 'apps/web/app/api/sessions/start'
ensure_dir 'apps/web/app/api/sessions/end'
ensure_dir 'apps/web/app/api/stripe/checkout'
ensure_dir 'apps/web/app/api/centers/near'

# env examples
if [ ! -f 'apps/web/.env.development.example' ]; then
  cat > 'apps/web/.env.development.example' << 'ENV'
NEXT_PUBLIC_ENV=development
NEXT_PUBLIC_GATEWAY_URL=http://localhost:4000
NEXT_PUBLIC_SUPABASE_URL=https://DEV_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_ANON_KEY=DEV_SUPABASE_ANON_KEY
NEXT_PUBLIC_STRIPE_PK=pk_test_***
NEXT_PUBLIC_EMERGENCY_MODE=true
NEXT_PUBLIC_SHOW_PRICING=true
NEXT_PUBLIC_SUPPORT_WHATSAPP=
NEXT_PUBLIC_DEFAULT_LANGUAGE=es
ENV
fi
[ -f 'apps/web/.env.staging.example' ] || cp 'apps/web/.env.development.example' 'apps/web/.env.staging.example'
[ -f 'apps/web/.env.production.example' ] || cp 'apps/web/.env.development.example' 'apps/web/.env.production.example'

# macOS-safe sed (ignore errors if not present)
sed -i '' 's/NEXT_PUBLIC_ENV=development/NEXT_PUBLIC_ENV=staging/' 'apps/web/.env.staging.example' 2>/dev/null || true
sed -i '' 's/NEXT_PUBLIC_ENV=development/NEXT_PUBLIC_ENV=production/' 'apps/web/.env.production.example' 2>/dev/null || true

# stub files
ensure_file 'apps/web/middleware.ts'
ensure_file 'apps/web/lib/env.ts'
ensure_file 'apps/web/lib/flags.ts'
ensure_file 'apps/web/app/(marketing)/layout.tsx'
ensure_file 'apps/web/app/(marketing)/page.tsx'
ensure_file 'apps/web/app/(app)/layout.tsx'
ensure_file 'apps/web/app/(app)/page.tsx'
ensure_file 'apps/web/app/(app)/start/page.tsx'
ensure_file 'apps/web/app/(app)/patients/page.tsx'
ensure_file 'apps/web/app/(app)/subscription/page.tsx'
ensure_file 'apps/web/app/(app)/chat/[sessionId]/page.tsx'
ensure_file 'apps/web/app/(app)/video/[roomId]/page.tsx'
ensure_file 'apps/web/app/api/sessions/start/route.ts'
ensure_file 'apps/web/app/api/sessions/end/route.ts'
ensure_file 'apps/web/app/api/stripe/checkout/route.ts'
ensure_file 'apps/web/app/api/centers/near/route.ts'
ensure_file 'apps/web/components/EmergencyBar.tsx'
ensure_file 'apps/web/components/StartConsultCard.tsx'
ensure_file 'apps/web/components/AuthModal.tsx'
ensure_file 'apps/web/components/PlanPicker.tsx'
ensure_file 'apps/web/components/UsageMeter.tsx'

# ensure prod env content (overwrite for correctness)
cat > 'apps/web/.env.production.example' << 'ENV'
NEXT_PUBLIC_ENV=production
NEXT_PUBLIC_GATEWAY_URL=https://api.callavet.mx
NEXT_PUBLIC_SUPABASE_URL=https://PROD_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_ANON_KEY=PROD_SUPABASE_ANON_KEY
NEXT_PUBLIC_STRIPE_PK=pk_live_***
NEXT_PUBLIC_EMERGENCY_MODE=false
NEXT_PUBLIC_SHOW_PRICING=true
NEXT_PUBLIC_SUPPORT_WHATSAPP=
NEXT_PUBLIC_DEFAULT_LANGUAGE=es
ENV

# ---------- admin stubs ----------
say "5) Scaffolding admin stubs"
ensure_dir 'apps/admin/lib'
ensure_file 'apps/admin/.env.development.example'
ensure_file 'apps/admin/.env.staging.example'
ensure_file 'apps/admin/.env.production.example'
ensure_file 'apps/admin/next.config.mjs'
ensure_file 'apps/admin/lib/env.ts'

# ---------- services ----------
say "6) Scaffolding services (webhooks only for now; Nest apps optional later)"
ensure_dir services/webhooks
pushd services/webhooks >/dev/null

if [ ! -f package.json ]; then
  cat > tsconfig.json << 'JSON'
{ "compilerOptions": { "target": "ES2020", "module": "CommonJS", "esModuleInterop": true, "outDir": "dist", "strict": true } }
JSON
  ensure_dir src
  cat > package.json << 'JSON'
{
  "name": "@cav/webhooks",
  "private": true,
  "type": "commonjs",
  "scripts": {
    "dev": "ts-node-dev --respawn src/index.ts",
    "build": "tsc",
    "start": "node dist/index.js"
  },
  "dependencies": {
    "body-parser": "^1.20.3",
    "express": "^4.19.2",
    "stripe": "^16.0.0"
  },
  "devDependencies": {
    "@types/express": "^4.17.21",
    "@types/node": "^22.7.4",
    "ts-node-dev": "^2.0.0",
    "typescript": "^5.6.3"
  }
}
JSON
  cat > src/index.ts << 'TS'
import express from "express";
import Stripe from "stripe";
import bodyParser from "body-parser";
const app = express();
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY || "", { apiVersion: "2024-06-20" });
const endpointSecret = process.env.STRIPE_WEBHOOK_SECRET || "";
app.post("/stripe/webhook", bodyParser.raw({ type: "application/json" }), (req, res) => {
  const sig = req.headers["stripe-signature"] as string;
  try { stripe.webhooks.constructEvent(req.body, sig, endpointSecret); }
  catch (e) { return res.sendStatus(400); }
  return res.json({ received: true });
});
app.get("/health", (_req,res)=>res.json({ok:true}));
app.listen(4200, ()=>console.log("Webhooks :4200"));
TS
fi
popd >/dev/null

# ---------- packages ----------
say "7) Scaffolding shared packages"
ensure_dir packages/ui packages/tsconfig packages/eslint-config packages/types/src packages/sdk/src packages/db/migrations packages/db/helpers

if [ ! -f packages/types/package.json ]; then
  cat > packages/types/package.json << 'JSON'
{ "name": "@cav/types", "version": "0.1.0", "main": "dist/index.js", "types": "dist/index.d.ts", "scripts": { "build":"tsc" } }
JSON
  cat > packages/types/tsconfig.json << 'JSON'
{ "compilerOptions": { "target": "ES2020", "module": "ESNext", "declaration": true, "outDir": "dist", "strict": true } }
JSON
  cat > packages/types/src/index.ts << 'TS'
export type UUID = string;
export type Role = 'user' | 'vet' | 'admin';
TS
fi

if [ ! -f packages/sdk/package.json ]; then
  cat > packages/sdk/package.json << 'JSON'
{ "name": "@cav/sdk", "version":"0.1.0", "main":"dist/index.js", "types":"dist/index.d.ts", "scripts":{ "build":"tsc" }, "dependencies": { "zod":"^3.23.8" } }
JSON
  cat > packages/sdk/tsconfig.json << 'JSON'
{ "compilerOptions": { "target": "ES2020", "module": "ESNext", "declaration": true, "outDir": "dist", "strict": true } }
JSON
  cat > packages/sdk/src/index.ts << 'TS'
export class GatewayClient {
  constructor(private baseUrl: string){}
  async reserveChat(userId: string, sessionId: string){
    const r = await fetch(`${this.baseUrl}/subscriptions/reserve-chat`, { method:"POST", headers:{ "content-type":"application/json" }, body: JSON.stringify({ userId, sessionId })});
    return r.json();
  }
}
TS
fi

if [ ! -f packages/db/package.json ]; then
  cat > packages/db/package.json << 'JSON'
{ "name": "@cav/db", "version":"0.1.0", "scripts": { "migrate:dev":"echo Run psql with DEV DATABASE_URL", "migrate:staging":"echo Run psql with STAGING DATABASE_URL", "migrate:prod":"echo Run psql with PROD DATABASE_URL" } }
JSON
  cat > packages/db/.env.development.example << 'ENV'
DATABASE_URL=postgres://USER:PASS@HOST:5432/db_dev
ENV
  cat > packages/db/.env.staging.example << 'ENV'
DATABASE_URL=postgres://USER:PASS@HOST:5432/db_staging
ENV
  cat > packages/db/.env.production.example << 'ENV'
DATABASE_URL=postgres://USER:PASS@HOST:5432/db_prod
ENV
fi

# ---------- infra ----------
say "8) Scaffolding infra"
ensure_dir infra/k8s/base
ensure_dir infra/k8s/overlays/staging
ensure_dir infra/k8s/overlays/prod
ensure_dir infra/supabase
ensure_dir infra/livekit

if [ ! -f infra/docker-compose.yml ]; then
  cat > infra/docker-compose.yml << 'YAML'
services:
  gateway:
    build: ../services/gateway-api
    working_dir: /app
    ports: ["4000:4000"]
    environment:
      - NODE_ENV=${NODE_ENV:-development}
    command: pnpm start
  chat:
    build: ../services/chat-service
    working_dir: /app
    ports: ["4100:4100"]
    environment:
      - NODE_ENV=${NODE_ENV:-development}
    command: pnpm start
  webhooks:
    build: ../services/webhooks
    working_dir: /app
    ports: ["4200:4200"]
    command: pnpm dev
YAML
fi

ensure_file infra/docker-compose.staging.yml
ensure_file infra/docker-compose.prod.yml
ensure_file infra/supabase/README.md
ensure_file infra/livekit/README.md

# ---------- install ----------
say "9) Installing root deps"
pnpm install

# convenience: add zod to web/admin if missing
say "10) Ensuring zod in web/admin"
# try path filter first, then by package name; don't fail if not matched
pnpm --filter ./apps/web add zod || pnpm --filter web add zod || true
pnpm --filter ./apps/admin add zod || pnpm --filter admin add zod || true

say "✅ Done! Next steps:
- cd apps/web && pnpm dev   # run blended app (marketing + user)
- cd services/webhooks && pnpm dev  # run Stripe webhook receiver
- In another terminal: pnpm dev     # run all via turbo (once other services exist)"
