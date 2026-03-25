#!/usr/bin/env bash
# docker/entrypoint.sh
#
# Runs once when the container starts, before handing off to CMD (supervisord).
# Responsibilities:
#   1. Wait for MySQL and Redis to be ready
#   2. Run database migrations (idempotent — safe to run on every deploy)
#   3. Warm the Laravel config/route/view caches
#   4. Hand off to supervisord → octane:start
#
# This script is used by BOTH the app container (→ supervisord → octane)
# AND the queue/scheduler containers (→ artisan queue:work / schedule:run).
# It is safe to run in all cases because migrations and cache-warm are idempotent.

set -euo pipefail

APP_DIR=/var/www/html

log() { echo "[entrypoint] $*"; }

# ── 1. Wait for MySQL ─────────────────────────────────────────────────────────
log "Waiting for MySQL at ${DB_HOST:-mysql}:${DB_PORT:-3306}..."
for i in $(seq 1 60); do
    if php -r "
        \$pdo = new PDO(
            'mysql:host=${DB_HOST:-mysql};port=${DB_PORT:-3306};dbname=${DB_DATABASE:-laravel}',
            '${DB_USERNAME:-laravel}',
            '${DB_PASSWORD:-secret}',
            [PDO::ATTR_TIMEOUT => 2]
        );
        echo 'ok';
    " 2>/dev/null | grep -q ok; then
        log "MySQL ready."
        break
    fi
    log "MySQL not ready (attempt $i/60), waiting 2s..."
    sleep 2
done

# ── 2. Wait for Redis ─────────────────────────────────────────────────────────
log "Waiting for Redis at ${REDIS_HOST:-redis}:${REDIS_PORT:-6379}..."
for i in $(seq 1 30); do
    if php -r "
        \$sock = fsockopen('${REDIS_HOST:-redis}', ${REDIS_PORT:-6379}, \$errno, \$errstr, 2);
        if (\$sock) { fclose(\$sock); echo 'ok'; }
    " 2>/dev/null | grep -q ok; then
        log "Redis ready."
        break
    fi
    log "Redis not ready (attempt $i/30), waiting 2s..."
    sleep 2
done

cd "${APP_DIR}"

# ── 3. Database migrations ────────────────────────────────────────────────────
log "Running migrations..."
php artisan migrate --force --no-interaction

# ── 4. Warm application caches ───────────────────────────────────────────────
# Only cache in production — in local dev, --watch handles restarts
if [ "${APP_ENV:-production}" != "local" ]; then
    log "Caching config, routes, views, events..."
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache
    php artisan event:cache
else
    log "Local env detected — skipping cache warm (using --watch mode)"
    php artisan config:clear
    php artisan route:clear
    php artisan view:clear
fi

# ── 5. Fix storage permissions ────────────────────────────────────────────────
log "Ensuring storage is writable..."
chmod -R 775 storage bootstrap/cache 2>/dev/null || true

log "Bootstrap complete. Starting: $*"
exec "$@"
