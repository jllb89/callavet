#!/usr/bin/env bash
set -euo pipefail

: "${REGISTRY_OWNER:?Set REGISTRY_OWNER to your GitHub org/user}"
TAG_DEFAULT="staging"
TAG_VALUE="${TAG:-$TAG_DEFAULT}"

# Required runtime env for services (provide via env/.env.staging.example)
: "${DATABASE_URL:?DATABASE_URL must be set}"
: "${SUPABASE_JWT_SECRET:?SUPABASE_JWT_SECRET must be set}"

cd "$(dirname "$0")/.."

echo "Deploying images ghcr.io/${REGISTRY_OWNER}/cav-*: ${TAG_VALUE}"

docker compose -f docker-compose.staging.yml pull || true

docker compose -f docker-compose.staging.yml up -d

echo "Deployed. Check logs with: docker compose -f docker-compose.staging.yml logs -f --tail=200"
