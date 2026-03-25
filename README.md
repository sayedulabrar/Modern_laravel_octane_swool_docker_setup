# Laravel 11 · Octane · Swoole · Docker Starter

A clean, production-ready scaffold for migrating to Laravel Octane with Swoole.
No application code — just the infrastructure, packages, and configuration done right.

## Stack

| Layer | Technology |
|---|---|
| Language | PHP 8.3 |
| Framework | Laravel 11 |
| HTTP Server | Laravel Octane 2.x + Swoole 6.x |
| Reverse Proxy | Nginx 1.25 |
| Database | MySQL 8.0 |
| Cache / Queue / Sessions | Redis 7 |
| Auth tokens | Laravel Passport 12 |
| Object Storage | MinIO (S3-compatible, local dev) |
| Container runtime | Docker + Docker Compose v2 |

---

## Prerequisites

- Docker Desktop (or Docker Engine + Compose v2)
- Git

That's it. PHP and Composer do not need to be installed on your host machine.

---

## Quick start

```bash
# 1. Clone
git clone <this-repo> my-app
cd my-app

# 2. Bootstrap (copies .env, installs packages, generates keys, runs migrations)
./scripts/setup.sh

# 3. Start
docker compose up -d

# 4. Open
open http://localhost        # → Nginx → Octane
open http://localhost:8025   # → Mailpit (local email)
open http://localhost:9001   # → MinIO console
```

The welcome page confirms Octane + Swoole are running.

---

## Daily commands

```bash
# Artisan
docker compose exec app php artisan <command>

# Composer
docker compose exec app composer <command>

# Reload Octane after code changes (faster than restart)
docker compose exec app php artisan octane:reload

# Tail all logs
docker compose logs -f

# Tail Octane specifically
docker compose logs -f app

# Scale queue workers up/down
docker compose up -d --scale queue=4

# Stop everything
docker compose down

# Stop and wipe all data (volumes)
docker compose down -v
```

---

## Project structure

```
.
├── docker/
│   ├── nginx/default.conf          Reverse proxy → Octane
│   ├── php/php.ini                 PHP tuned for long-running Swoole process
│   ├── php/opcache.ini             OPcache + JIT enabled
│   ├── mysql/my.cnf                MySQL 8 tuning
│   └── supervisor/supervisord.conf Starts octane:start inside container
├── scripts/
│   ├── setup.sh                    One-time bootstrap
│   └── deploy.sh                   Zero-downtime redeploy helper
├── Dockerfile                      Multi-stage: deps → assets → production
├── docker-compose.yml              All services wired together
├── docker-compose.override.yml     Dev overrides (Xdebug, hot-reload, Mailpit)
├── .env.example                    All variables documented
└── (Laravel 11 app files)          Standard Laravel structure
```

---

## Migrating your existing code

The recommended approach is additive: build features in this project and
verify them against the old codebase, rather than editing the old project
directly. Key things to handle when porting:

1. **PHP 8.x syntax** — typed properties, named args, match expressions, enums
2. **Laravel 11 bootstrapping** — `bootstrap/app.php` replaces most Providers
3. **Octane memory safety** — no static state that persists across requests
4. **Intervention Image v3** — new API (see PORTING.md)
5. **Passport 12** — keys stored in `storage/passport/`, new middleware names

See `PORTING.md` for a step-by-step checklist.
