# PORTING.md
# Moving code from Laravel 8 / PHP 7.4 → this project

This is your working checklist. Work through it top to bottom, one section
at a time. Each section is independent — you can port Models before Routes,
or Services before Controllers. Go at your own pace.

---

## Before you start

```bash
# Keep both projects open side by side
# Old project: your-old-app/
# New project: laravel-octane-starter/  ← this repo

# Confirm the new project is running
curl http://localhost/up          # should return HTTP 200
curl http://localhost/api/status  # should return JSON with octane: true
```

---

## Section 1 — PHP 8.x syntax modernisation

You don't have to do this all at once — PHP 8 is backwards-compatible for
most PHP 7.4 code. Port files first, modernise syntax gradually.

### Things that WILL break (must fix before running)

| Old (PHP 7.4) | New (PHP 8.x) | Notes |
|---|---|---|
| `array` typehints on class properties | `array` still works | No change needed |
| `mixed` return type | `mixed` is now a real type | Optionally add it |
| `\Throwable` catch | Same | No change |
| Named arguments don't exist | `fn(foo: $x)` now works | Optional improvement |
| `str_contains` doesn't exist | Now built-in | Remove any polyfills |

### Things that changed in PHP 8 that are safe to ignore initially

- `match` expression (use `switch` still — both work)
- Enums (use class constants still — both work)
- Constructor property promotion (optional)
- Nullsafe operator `?->` (optional improvement)
- Union types `int|string` (optional)
- Named arguments (optional)

### Quick scan for obvious issues

```bash
# In your OLD project directory — find PHP 7-only patterns
grep -rn "create_function"  app/    # removed in PHP 8
grep -rn "each("            app/    # removed in PHP 8
grep -rn "\$HTTP_"          app/    # old superglobals
```

---

## Section 2 — Laravel 11 bootstrap changes

### What changed

Laravel 11 eliminated `app/Http/Kernel.php`, `app/Console/Kernel.php`,
and most of `app/Providers/`. Everything moved into `bootstrap/app.php`.

### Middleware

```php
// OLD (app/Http/Kernel.php) — does not exist in Laravel 11
protected $middlewareGroups = [
    'api' => [
        \App\Http\Middleware\MyMiddleware::class,
    ],
];
protected $routeMiddleware = [
    'auth.custom' => \App\Http\Middleware\CustomAuth::class,
];

// NEW (bootstrap/app.php)
->withMiddleware(function (Middleware $middleware) {
    $middleware->api(append: [
        \App\Http\Middleware\MyMiddleware::class,
    ]);
    $middleware->alias([
        'auth.custom' => \App\Http\Middleware\CustomAuth::class,
    ]);
})
```

### Service Providers

```php
// OLD — app/Providers/AppServiceProvider.php registered many things
// NEW — most is auto-discovered. Only register what's truly custom.
// Your custom providers still go in config/app.php → 'providers' array,
// OR use the new bootstrap/providers.php file (Laravel 11 auto-loads it).
```

Create `bootstrap/providers.php` for your custom providers:
```php
<?php
return [
    App\Providers\OctaneServiceProvider::class,
    // App\Providers\AuthServiceProvider::class,   // if you need custom gates/policies
    // App\Providers\EventServiceProvider::class,  // if you have many listeners
];
```

### Scheduled tasks

```php
// OLD (app/Console/Kernel.php)
protected function schedule(Schedule $schedule): void {
    $schedule->command('emails:send')->daily();
}

// NEW (routes/console.php)
use Illuminate\Support\Facades\Schedule;

Schedule::command('emails:send')->daily();
```

---

## Section 3 — Models

Models copy over almost unchanged. Changes to make:

```php
// OLD
class User extends Authenticatable {
    protected $guarded = [];
    // ...
}

// NEW — add these PHP 8 improvements as you go (optional)
class User extends Authenticatable {
    // Cast to native types
    protected $casts = [
        'email_verified_at' => 'datetime',
        'is_admin'          => 'boolean',   // was: 'integer' or '0/1'
        'metadata'          => 'array',
        'created_at'        => 'datetime',
    ];
}
```

### Copy models

```bash
cp old-project/app/Models/*.php  laravel-octane-starter/app/Models/
```

Then review each one for:
- [ ] Any static properties (dangerous in Octane — see Section 7)
- [ ] Relationships that store resolved instances statically
- [ ] Any use of `app()` inside a model constructor

---

## Section 4 — Database migrations

Migrations copy over unchanged. Laravel's migration system hasn't changed.

```bash
cp old-project/database/migrations/*.php  laravel-octane-starter/database/migrations/
cp old-project/database/seeders/*.php     laravel-octane-starter/database/seeders/
cp old-project/database/factories/*.php   laravel-octane-starter/database/factories/

# Run them
docker compose exec app php artisan migrate:fresh --seed
```

---

## Section 5 — Passport migration

### Install fresh keys

```bash
docker compose exec app php artisan passport:install --force
```

### Middleware names changed

```php
// OLD (Laravel Passport 10)
Route::middleware('auth:api')
Route::middleware('client')
Route::middleware('scopes:read,write')
Route::middleware('scope:read')

// NEW (Passport 12) — all still work, but prefer explicit class names
Route::middleware('auth:passport')  // or still 'auth:api' — both work
Route::middleware(\Laravel\Passport\Http\Middleware\CheckClientCredentials::class)
Route::middleware(\Laravel\Passport\Http\Middleware\CheckScopes::class.':read,write')
Route::middleware(\Laravel\Passport\Http\Middleware\CheckForAnyScope::class.':read')
```

### User model

```php
// Make sure your User model uses HasApiTokens from Passport (not Sanctum)
use Laravel\Passport\HasApiTokens;

class User extends Authenticatable {
    use HasApiTokens, HasFactory, Notifiable;
}
```

### config/auth.php — set the driver

```php
'guards' => [
    'api' => [
        'driver'   => 'passport',  // was 'token' in some old configs
        'provider' => 'users',
    ],
],
```

---

## Section 6 — Intervention Image v3

Every `Image::make()` call needs updating. This is the most mechanical part.

### Find all usages

```bash
grep -rn "Image::" old-project/app/ --include="*.php"
grep -rn "Image::make" old-project/app/ --include="*.php"
```

### API changes

```php
// OLD (v2)
use Intervention\Image\Facades\Image;

$img = Image::make($request->file('photo'))
    ->resize(800, null, function ($c) { $c->aspectRatio(); })
    ->encode('jpg', 85)
    ->save(storage_path('uploads/photo.jpg'));

// NEW (v3)
use Intervention\Image\Laravel\Facades\Image;
use Intervention\Image\Encoders\JpegEncoder;

$img = Image::read($request->file('photo'))
    ->scaleDown(width: 800)         // maintains aspect ratio automatically
    ->encode(new JpegEncoder(85))
    ->save(storage_path('uploads/photo.jpg'));
```

```php
// OLD — resize with both dimensions
->resize(400, 300)

// NEW
->resize(400, 300)  // same! basic resize unchanged
->cover(400, 300)   // crop to exact size (was: fit in v2)
->scale(400, 300)   // fit within box maintaining ratio
->scaleDown(400, 300) // only shrink, never enlarge
```

```php
// OLD — get image as string
$data = Image::make($path)->encode('png')->getEncoded();

// NEW
use Intervention\Image\Encoders\PngEncoder;
$data = Image::read($path)->encode(new PngEncoder())->toString();
```

---

## Section 7 — Octane memory safety audit

**This is the most important section.** Before porting any service class,
run it through this checklist.

### Rule 1: No static properties that accumulate data

```php
// DANGEROUS — grows forever across all requests in a worker
class ProductService {
    private static array $cache = [];

    public function find(int $id): Product {
        if (!isset(static::$cache[$id])) {
            static::$cache[$id] = Product::find($id);  // never freed
        }
        return static::$cache[$id];
    }
}

// SAFE — use Laravel's cache (Redis) instead
class ProductService {
    public function find(int $id): Product {
        return cache()->remember("product:{$id}", 300, fn() => Product::find($id));
    }
}
```

### Rule 2: No per-request state in singletons

```php
// DANGEROUS — $this->user is set from the FIRST request and never reset
class ReportService {
    private ?User $user = null;

    public function boot(): void {
        $this->user = auth()->user();   // request 1's user stays forever
    }
}

// SAFE — resolve auth lazily, per call
class ReportService {
    public function generateFor(User $user): array { ... }
    // OR
    public function generate(): array {
        $user = auth()->user();  // resolved fresh each call
        ...
    }
}
```

### Rule 3: Singletons registered in ServiceProviders

```php
// REVIEW each app()->singleton(...) in your old AppServiceProvider
// Ask: does this service store anything that changes per request?

// SAFE to singleton:
app()->singleton(PdfRenderer::class, fn() => new PdfRenderer());  // stateless
app()->singleton(CurrencyConverter::class, fn() => new CurrencyConverter());  // reads only

// DANGEROUS to singleton:
app()->singleton(CartService::class, fn() => new CartService(auth()->user()));  // stores user
```

### Quick scan for risky patterns

```bash
grep -rn "static \$"           app/     # static properties
grep -rn "static::$"           app/     # static property access
grep -rn "self::$"             app/     # static property access
grep -rn "private static"      app/     # static state
grep -rn "protected static"    app/     # static state
grep -rn "singleton"           app/Providers/
```

---

## Section 8 — Package-specific notes

### spatie/laravel-activitylog v3 → v4

```php
// Config key changed: old config/activitylog.php keys still work
// but run: php artisan vendor:publish --provider="Spatie\Activitylog\ActivitylogServiceProvider"
// to get the new config file.

// LogsActivity trait usage unchanged:
use Spatie\Activitylog\Traits\LogsActivity;
use Spatie\Activitylog\LogOptions;

class Post extends Model {
    use LogsActivity;

    public function getActivitylogOptions(): LogOptions {
        return LogOptions::defaults()->logFillable();
    }
}
```

### spatie/laravel-backup v6 → v8

```bash
# Republish the config — it changed significantly
docker compose exec app php artisan vendor:publish \
    --provider="Spatie\Backup\BackupServiceProvider" --force
```

### barryvdh/laravel-dompdf v0.8 → v2

```php
// OLD namespace
use Barryvdh\DomPDF\Facade as PDF;
$pdf = PDF::loadView('reports.invoice', $data);

// NEW namespace (v2)
use Barryvdh\DomPDF\Facade\Pdf;
$pdf = Pdf::loadView('reports.invoice', $data);
```

### maatwebsite/excel v3.1

No breaking changes between the version in your old project and what runs on
Laravel 11. Copy your Imports/Exports classes directly.

### knuckleswtf/scribe v3 → v4

```bash
# Republish config
docker compose exec app php artisan vendor:publish \
    --provider="Knuckles\Scribe\ScribeServiceProvider" --force

# Regenerate docs
docker compose exec app php artisan scribe:generate
```

---

## Section 9 — Routes

```bash
# Copy route files
cp old-project/routes/api.php  laravel-octane-starter/routes/api_old.php
cp old-project/routes/web.php  laravel-octane-starter/routes/web_old.php

# Merge manually — don't overwrite the new api.php which has the /status endpoint
```

When copying, wrap your old routes in a version prefix:
```php
// routes/api.php — add alongside existing routes
Route::prefix('v1')->group(function () {
    // paste your old API routes here
    require __DIR__ . '/api_old.php';
});
```

---

## Section 10 — Final checklist before going live

- [ ] All routes accessible: `php artisan route:list`
- [ ] All migrations run cleanly: `php artisan migrate:fresh`
- [ ] Queue jobs fire correctly: `php artisan queue:work` + dispatch a test job
- [ ] Scheduler runs: `php artisan schedule:run`
- [ ] Passport tokens issue: test login → get token → hit protected route
- [ ] File uploads work: test with MinIO/S3 disk
- [ ] PDFs generate: test a dompdf route
- [ ] No memory leaks: run `wrk -t4 -c100 -d30s http://localhost/api/status`
  and check `docker stats` — memory should be stable, not growing
- [ ] Octane reload works: `php artisan octane:reload` (used in deploys)
