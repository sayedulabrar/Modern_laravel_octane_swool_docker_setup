#!/usr/bin/env bash
# scripts/deploy.sh
#
# Rebuild and redeploy the application.
# Uses Octane's graceful reload to avoid downtime:
#   1. New workers start and begin accepting requests
#   2. Old workers finish their in-flight requests
#   3. Old workers exit
#
# Usage: ./scripts/deploy.sh [--no-cache]

set -euo pipefail

NO_CACHE=${1:-}

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${CYAN}▶ $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }

log "Building new image..."
docker compose build ${NO_CACHE} app

log "Running migrations..."
docker compose run --rm app php artisan migrate --force --no-interaction

log "Refreshing caches..."
docker compose exec app php artisan config:cache
docker compose exec app php artisan route:cache
docker compose exec app php artisan view:cache
docker compose exec app php artisan event:cache

log "Gracefully reloading Octane workers..."
docker compose exec app php artisan octane:reload
success "Octane reloaded — no downtime"

log "Restarting queue workers..."
docker compose up -d --no-deps queue
success "Queue workers restarted"

success "Deploy complete."
