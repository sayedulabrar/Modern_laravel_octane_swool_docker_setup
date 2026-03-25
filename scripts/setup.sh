#!/usr/bin/env bash
# scripts/setup.sh
#
# One-time project bootstrap. Run this ONCE after cloning the repo.
# Safe to re-run — all steps are idempotent.
#
# Usage: ./scripts/setup.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

log()     { echo -e "${CYAN}▶ $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
error()   { echo -e "${RED}✗ $*${NC}"; }

# Cleanup on error or interrupt — stop all containers
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        error "Setup failed or interrupted."
        warn "Stopping Docker services..."
        docker compose down 2>/dev/null || true
        echo "   To clean up manually: docker compose down && sudo chown -R \$USER:\$USER ."
    fi
    exit $exit_code
}

trap cleanup EXIT INT TERM

log "Laravel Octane + Swoole — project setup"
echo ""

# ── Check Docker ──────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo "Docker is not installed. Install Docker Desktop and retry."
    exit 1
fi
if ! docker compose version &>/dev/null; then
    echo "Docker Compose v2 not found. Update Docker Desktop and retry."
    exit 1
fi
success "Docker $(docker --version | cut -d' ' -f3 | tr -d ',')"

# ── Make scripts executable ───────────────────────────────────────────────────
log "Setting execute permissions on scripts..."
chmod +x docker/entrypoint.sh scripts/deploy.sh
success "Scripts are executable"

# ── Copy .env ─────────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
    log "Copying .env.example → .env"
    cp .env.example .env
    success ".env created"
else
    warn ".env already exists — skipping copy"
fi

# ── Build images ──────────────────────────────────────────────────────────────
log "Building Docker images (first build takes a few minutes)..."
docker compose build --no-cache
success "Images built"

# ── Start infrastructure services only ───────────────────────────────────────
# App container is NOT started yet — octane:install must run first
log "Starting MySQL, Redis, MinIO, and Mailpit..."
docker compose up -d mysql redis minio mailpit
echo "   Waiting 15s for services to initialise..."
sleep 15
success "Infrastructure services running"

# ── Create Laravel project ───────────────────────────────────────────────────────────────
log "Creating Laravel 11 skeleton..."
docker compose run --rm --no-deps \
    -e COMPOSER_ALLOW_SUPERUSER=1 \
    app composer create-project laravel/laravel:^11.0 . --prefer-dist --no-interaction
success "Laravel project created"

# ── Generate app key ──────────────────────────────────────────────────────────
log "Generating application key..."
docker compose run --rm --no-deps app php artisan key:generate --force
success "APP_KEY generated"

# ── Install Octane + Swoole ───────────────────────────────────────────────────
# Must run BEFORE the app container starts because it generates config/octane.php
# which supervisord needs when it runs octane:start inside the container.
log "Installing Laravel Octane (generates config/octane.php)..."
docker compose run --rm --no-deps app php artisan octane:install --server=swoole --no-interaction
success "Octane installed"

# ── Run migrations ────────────────────────────────────────────────────────────
# Run before starting the full stack so the DB is ready when the app boots.
log "Running database migrations..."
docker compose run --rm app php artisan migrate --force --no-interaction
success "Migrations complete"

# ── Start full stack ──────────────────────────────────────────────────────────
# config/octane.php now exists — the app container can boot cleanly.
log "Starting all services..."
docker compose up -d
echo "   Waiting for Octane healthcheck..."
sleep 20
success "All services started"

# ── Install Passport keys ─────────────────────────────────────────────────────
log "Installing Passport OAuth keys..."
docker compose exec app php artisan passport:install --force 2>/dev/null \
    && success "Passport keys installed" \
    || warn "Passport install skipped — run manually: docker compose exec app php artisan passport:install"

# ── Create MinIO bucket ───────────────────────────────────────────────────────
log "Creating default MinIO bucket..."
docker compose exec app php artisan tinker --execute="
    \$s3 = \Illuminate\Support\Facades\Storage::disk('s3');
    try { \$s3->makeDirectory(''); echo 'Bucket ready'; }
    catch (\\Exception \$e) { echo 'Bucket may already exist: ' . \$e->getMessage(); }
" 2>/dev/null || warn "MinIO bucket creation skipped — create manually at http://localhost:9001"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo ""
echo "  App (via Nginx)     → http://localhost"
echo "  Mailpit (email UI)  → http://localhost:8025"
echo "  MinIO console       → http://localhost:9001"
echo "  MySQL (host)        → localhost:33060"
echo ""
echo "  docker compose logs -f app   ← tail Octane logs"
echo "  ./scripts/deploy.sh          ← rebuild & reload"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"