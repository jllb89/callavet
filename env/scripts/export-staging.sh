#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

export NODE_ENV=staging

if [[ -f "$ROOT_DIR/.env.staging" ]]; then
	set -a
	# shellcheck disable=SC1090
	source "$ROOT_DIR/.env.staging"
	set +a
fi
