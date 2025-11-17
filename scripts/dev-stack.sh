#!/usr/bin/env bash
set -euo pipefail

# Unified local development stack launcher
# 1. Ensure Postgres is up (docker compose) if DATABASE_URL not set
# 2. Export OpenAPI spec path for gateway docs if available
# 3. Run turbo dev across selected packages (web, admin, gateway-api, chat-service)
# 4. Provide helpful output & ctrl-c handling

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Allow passing KEY=VALUE pairs after the script invocation (e.g. pnpm run dev:stack DEV_FORCE_RESTART_NEXT=1)
for arg in "$@"; do
  if [[ "$arg" == *=* ]]; then
    export "$arg" # shellcheck disable=SC2163
  fi
done

# Optionally load .env into the environment for app processes (default on)
DEV_LOAD_DOTENV="${DEV_LOAD_DOTENV:-1}"
if [[ "$DEV_LOAD_DOTENV" != "0" && -f "$ROOT_DIR/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT_DIR/.env"
  set +a
  echo "[dev-stack] Loaded .env into environment"
fi

DEV_SKIP_DOCKER="${DEV_SKIP_DOCKER:-1}"      # Default: skip bringing up docker-compose infra (avoid starting old containers)
DEV_FORCE_GATEWAY="${DEV_FORCE_GATEWAY:-}"   # If set, force starting gateway dev even if port busy
DEV_FORCE_CHAT="${DEV_FORCE_CHAT:-}"         # If set, force starting chat dev even if port busy
DEV_FORCE_RESTART_NEXT="${DEV_FORCE_RESTART_NEXT:-}" # If set, kill existing dev processes (Next + ts-node-dev) & restart clean
DEV_FORCE_RESTART_INFRA="${DEV_FORCE_RESTART_INFRA:-}" # If set with restart, docker compose down && up for clean infra
DEV_SKIP_WEB="${DEV_SKIP_WEB:-}"             # If set, skip starting web next dev
DEV_SKIP_ADMIN="${DEV_SKIP_ADMIN:-}"         # If set, skip starting admin next dev

if [[ -z "${DATABASE_URL:-}" && -z "${DEV_SKIP_DOCKER:-}" ]]; then
  echo "[dev-stack] DATABASE_URL not set; skipping docker compose (DEV_SKIP_DOCKER=1 default). Ensure your DB is reachable."
fi

if [[ -n "$DEV_FORCE_RESTART_NEXT" && -n "$DEV_FORCE_RESTART_INFRA" && -z "$DEV_SKIP_DOCKER" ]]; then
  echo "[dev-stack] DEV_FORCE_RESTART_INFRA=1 -> restarting docker infra cleanly." 
  docker compose -f infra/docker-compose.yml down || true
  docker compose -f infra/docker-compose.yml up -d || echo "[dev-stack] Warning: infra restart encountered an issue." >&2
fi

# Fallback DATABASE_URL if still unset after optional docker start
if [[ -z "${DATABASE_URL:-}" ]]; then
  export DATABASE_URL="postgres://postgres:postgres@localhost:5432/postgres"
  echo "[dev-stack] Set fallback DATABASE_URL=$DATABASE_URL"
else
  # Briefly acknowledge source for clarity
  if [[ -f "$ROOT_DIR/.env" ]]; then
    echo "[dev-stack] Using DATABASE_URL from .env (${DATABASE_URL%%\?*})"
  fi
fi

# Provide OPENAPI spec path if exists and not already set
if [[ -z "${OPENAPI_SPEC_PATH:-}" ]]; then
  SPEC_CANDIDATE="${ROOT_DIR}/docs/openapi/openapi.yaml"
  if [[ -f "$SPEC_CANDIDATE" ]]; then
    export OPENAPI_SPEC_PATH="$SPEC_CANDIDATE"
    echo "[dev-stack] OPENAPI_SPEC_PATH set to $OPENAPI_SPEC_PATH"
  fi
fi

# Chat, gateway & webhooks expected ports
export PORT_GATEWAY=4000
export PORT_CHAT=4100
export PORT_WEBHOOKS=4200

port_in_use(){
  local p="$1"
  if lsof -ti tcp:"$p" >/dev/null 2>&1; then return 0; fi
  return 1
}

# Attempt to free a TCP port by terminating processes holding it.
# Respects DEV_AUTO_FREE_PORTS (default=1). If set to 0, no cleanup is performed.
DEV_AUTO_FREE_PORTS="${DEV_AUTO_FREE_PORTS:-1}"
free_port(){
  local p="$1"
  if [[ "$DEV_AUTO_FREE_PORTS" == "0" ]]; then return 0; fi
  local pids
  pids="$(lsof -ti tcp:"$p" || true)"
  if [[ -n "$pids" ]]; then
    echo "[dev-stack] Port $p occupied by PID(s): $pids; attempting graceful termination."
    kill $pids 2>/dev/null || true
    sleep 0.5
    if lsof -ti tcp:"$p" >/dev/null 2>&1; then
      echo "[dev-stack] Port $p still busy; sending SIGKILL."
      kill -9 $pids 2>/dev/null || true
      sleep 0.2
    fi
    if lsof -ti tcp:"$p" >/dev/null 2>&1; then
      echo "[dev-stack] Warning: port $p still appears busy after forced kill." >&2
    else
      echo "[dev-stack] Port $p successfully freed."
    fi
  fi
}

# Clean stale Next.js dev lock files if no process holds the port they previously used
cleanup_next_lock(){
  local app_dir="$1"
  local lock_file="${app_dir}/.next/dev/lock"
  if [[ -f "$lock_file" ]]; then
    # If no next dev process running for this app, remove lock
    if ! grep -q "next" <(ps -o pid,command -ax) 2>/dev/null; then
      rm -f "$lock_file" && echo "[dev-stack] Removed stale lock: $lock_file"
    fi
  fi
}

cleanup_next_lock "apps/admin"
cleanup_next_lock "apps/web"

is_next_running_for(){
  local app_dir="$1" # e.g. apps/admin
  # Match next dev processes whose command path includes the app directory
  if ps -o pid,command -ax | grep -E "next dev" | grep -q "${app_dir}"; then
    return 0
  fi
  return 1
}

if [[ -n "$DEV_FORCE_RESTART_NEXT" ]]; then
  echo "[dev-stack] DEV_FORCE_RESTART_NEXT=1 -> terminating existing dev processes (Next, gateway, chat)."
  # Kill Next dev processes (admin/web)
  for pat in "${ROOT_DIR}/apps/admin/.*next.*dev" "${ROOT_DIR}/apps/web/.*next.*dev"; do
    pgrep -f "$pat" >/dev/null 2>&1 && pkill -f "$pat" 2>/dev/null || true
  done
  # Kill backend ts-node-dev processes (gateway/chat)
  for pat in "${ROOT_DIR}/services/gateway-api/.*ts-node-dev" "${ROOT_DIR}/services/chat-service/.*ts-node-dev"; do
    pgrep -f "$pat" >/dev/null 2>&1 && pkill -f "$pat" 2>/dev/null || true
  done
  # Clean locks & incremental caches
  rm -f apps/admin/.next/dev/lock 2>/dev/null || true
  rm -f apps/web/.next/dev/lock 2>/dev/null || true
  rm -rf apps/admin/.next/cache 2>/dev/null || true
  rm -rf apps/web/.next/cache 2>/dev/null || true
  echo "[dev-stack] Processes terminated; starting fresh after short delay." 
  sleep 1
fi

declare -a filters=()

if [[ -n "$DEV_SKIP_WEB" ]]; then
  echo "[dev-stack] Skipping web app (DEV_SKIP_WEB=1)."
else
  if is_next_running_for "apps/web" && [[ -z "$DEV_FORCE_RESTART_NEXT" ]]; then
    echo "[dev-stack] Detected existing Next dev for web (apps/web); skipping duplicate start. Use DEV_FORCE_RESTART_NEXT=1 for clean restart." 
  else
    filters+=("./apps/web")
  fi
fi

if [[ -n "$DEV_SKIP_ADMIN" ]]; then
  echo "[dev-stack] Skipping admin app (DEV_SKIP_ADMIN=1)."
else
  if is_next_running_for "apps/admin" && [[ -z "$DEV_FORCE_RESTART_NEXT" ]]; then
    echo "[dev-stack] Detected existing Next dev for admin (apps/admin); skipping duplicate start. Use DEV_FORCE_RESTART_NEXT=1 for clean restart." 
  else
    filters+=("./apps/admin")
  fi
fi

# Decide whether to start gateway/chat dev versions based on port availability (with container/port cleanup)
DEV_AUTO_STOP_CONTAINERS="${DEV_AUTO_STOP_CONTAINERS:-1}"
stop_containers_on_port(){
  local p="$1"
  [[ "$DEV_AUTO_STOP_CONTAINERS" == "0" ]] && return 0
  local ids
  ids="$(docker ps --format '{{.ID}} {{.Ports}}' 2>/dev/null | grep -E ":${p}->" | awk '{print $1}' || true)"
  if [[ -n "$ids" ]]; then
    echo "[dev-stack] Stopping container(s) using port $p: $ids"
    docker stop $ids >/dev/null 2>&1 || true
    sleep 0.5
  fi
}

# Optionally stop docker-compose services if any are up
DEV_AUTO_STOP_COMPOSE="${DEV_AUTO_STOP_COMPOSE:-1}"
stop_compose_services(){
  [[ "$DEV_AUTO_STOP_COMPOSE" == "0" ]] && return 0
  if command -v docker >/dev/null 2>&1 && command -v docker-compose >/dev/null 2>&1; then
    : # prefer docker-compose if available
  fi
  # Use docker compose v2 (plugin) if available
  if command -v docker >/dev/null 2>&1; then
    local up_any
    up_any="$(docker compose -f infra/docker-compose.yml ps -q 2>/dev/null || true)"
    if [[ -n "$up_any" ]]; then
      echo "[dev-stack] Detected compose services up; bringing them down to avoid port collisions."
      docker compose -f infra/docker-compose.yml down >/dev/null 2>&1 || true
    fi
  fi
}

# Gateway
if port_in_use "$PORT_GATEWAY"; then
  stop_compose_services
  stop_containers_on_port "$PORT_GATEWAY"
  if port_in_use "$PORT_GATEWAY"; then
    echo "[dev-stack] Port $PORT_GATEWAY busy; attempting free_port." 
    free_port "$PORT_GATEWAY"
  fi
fi
if port_in_use "$PORT_GATEWAY"; then
  if [[ -n "$DEV_FORCE_GATEWAY" ]]; then
    echo "[dev-stack] Port $PORT_GATEWAY still busy; DEV_FORCE_GATEWAY=1 -> starting anyway (may fail)."
    filters+=("@cav/gateway-api")
  else
    echo "[dev-stack] Skipping gateway dev (port $PORT_GATEWAY still busy)."
  fi
else
  filters+=("@cav/gateway-api")
fi

# Chat
if port_in_use "$PORT_CHAT"; then
  stop_compose_services
  stop_containers_on_port "$PORT_CHAT"
  if port_in_use "$PORT_CHAT"; then
    echo "[dev-stack] Port $PORT_CHAT busy; attempting free_port." 
    free_port "$PORT_CHAT"
  fi
fi
if port_in_use "$PORT_CHAT"; then
  if [[ -n "$DEV_FORCE_CHAT" ]]; then
    echo "[dev-stack] Port $PORT_CHAT still busy; DEV_FORCE_CHAT=1 -> starting anyway (may fail)."
    filters+=("@cav/chat-service")
  else
    echo "[dev-stack] Skipping chat dev (port $PORT_CHAT still busy)."
  fi
else
  filters+=("@cav/chat-service")
fi

# Webhooks (ensure no container occupies 4200 so local dev can use it if needed)
if port_in_use "$PORT_WEBHOOKS"; then
  stop_compose_services
  stop_containers_on_port "$PORT_WEBHOOKS"
  if port_in_use "$PORT_WEBHOOKS"; then
    echo "[dev-stack] Port $PORT_WEBHOOKS busy; attempting free_port." 
    free_port "$PORT_WEBHOOKS"
  fi
fi

echo "[dev-stack] Starting turbo dev for: ${filters[*]-}" 
# If nothing to start, exit gracefully
if [[ ${#filters[@]:-0} -eq 0 ]]; then
  echo "[dev-stack] Nothing to start (web/admin running; gateway/chat ports busy)."
  echo "[dev-stack] Active listeners:" && lsof -nPiTCP -sTCP:LISTEN | grep -E '(:3000|:3001|:3002|:4000|:4100)' || true
  exit 0
fi
pnpm turbo run dev $(printf ' --filter=%s' "${filters[@]:-}") --parallel || {
  echo "[dev-stack] turbo run exited with non-zero status." >&2
}

echo "[dev-stack] Active listeners:" && lsof -nPiTCP -sTCP:LISTEN | grep -E '(:3000|:3001|:3002|:4000|:4100|:4200)' || true

