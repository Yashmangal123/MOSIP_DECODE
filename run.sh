#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$ROOT_DIR/services/platform"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required. Install Docker Desktop and try again."
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 is required. Update Docker Desktop and try again."
  exit 1
fi

if [[ ! -f "$PLATFORM_DIR/.env" ]]; then
  cp "$PLATFORM_DIR/.env.example" "$PLATFORM_DIR/.env"
  echo "Created services/platform/.env from .env.example."
  echo "Before using real email OTP, edit that file and set valid SMTP credentials."
fi

cd "$PLATFORM_DIR"
exec docker compose -f deploy/docker-compose.yml up --build
