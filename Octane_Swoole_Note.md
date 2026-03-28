# Laravel Octane: Service Container Behavior, Sandboxing, and Advanced Features  

**Developer Notes & Best Practices**

---

### 1. Application Container Behavior in Laravel Octane

At boot time, the server creates the original application instance. **This instance is not directly used** to serve client requests.

**Important Clarification:**  

Laravel Octane **clones** the original instance (created when the server started) for each request. This ensures the Laravel service container remains in a **fresh state** for every single request.

- Any modifications made to the application container during a request **do not persist** to subsequent requests.  

- The next request receives a fresh clone from the original boot instance.  

- This also applies to the configuration repository — any runtime changes to config are **not carried over**.

**Example Code – /static Route (PHP-FPM):**

```php
// routes/web.php
Route::get('/static', function () {
    static $timestamps = [];
    $timestamps[] = now()->format('Y-m-d H:i:s.u');
    
    return view('timestamps', ['timestamps' => $timestamps]);
});

// Output: Fresh array on each request (always [])
// Request 1: ["2026-03-28 10:30:45.123456"]
// Request 2: ["2026-03-28 10:30:46.456789"]  <- Fresh array!
```

---

### 2. Service Binding Patterns in Standard Laravel (PHP-FPM)

In a **normal Laravel application using PHP-FPM**, both binding approaches below produce the **same end-user experience** — data is lost after the request completes.  

The real difference lies in **when** the object is instantiated and **how** it is stored in the container.

#### 4a. `register()` + `singleton` (Lazy Loading)

- **Behavior**: The object is created only when first requested (`app('store')`).  

- **Advantage**: Saves memory if the service is never used in a request.

```php
// app/Services/Store.php
namespace App\Services;

class Store
{
    protected array $data = [];
    
    public function set(string $key, mixed $value): void
    {
        $this->data[$key] = $value;
    }
    
    public function get(string $key, mixed $default = null): mixed
    {
        return $this->data[$key] ?? $default;
    }
    
    public function all(): array
    {
        return $this->data;
    }
    
    public function flush(): void
    {
        $this->data = [];
    }
}

// app/Providers/AppServiceProvider.php
namespace App\Providers;

use App\Services\Store;
use Illuminate\Support\ServiceProvider;

public function register()
{
    $this->app->singleton('store', function ($app) {
        return new Store(); // Executed only when/if needed
    });
    
    // Also register by class name for type-hinting
    $this->app->singleton(Store::class, function ($app) {
        return $app->make('store');
    });
}
```

#### 4b. `boot()` + `instance` (Eager Loading)

- **Behavior**: The object is created immediately during application bootstrapping, before routes are executed.

- **Use Case**: Ideal when the service needs to perform critical setup (e.g., event listeners, global configuration) at startup.

```php
// app/Providers/AppServiceProvider.php
namespace App\Providers;

use App\Services\Store;
use Illuminate\Support\ServiceProvider;

public function boot()
{
    $store = new Store();
    $store->set('init_time', microtime(true));
    $store->set('server_started', now());
    $store->set('worker_pid', getmypid());
    
    $this->app->instance('store', $store);
    $this->app->instance(Store::class, $store);
}

// Usage in routes or controllers:
// Route::get('/debug', function () {
//     $store = app('store');
//     return $store->all();
// });
```

#### Lifecycle Summary (PHP-FPM)

1. Request starts → PHP process wakes up.  

2. Service Providers boot:  

   - `register()` defines blueprints.  

   - `boot()` creates live objects.  

3. Route logic executes.  

4. Response is sent.  

5. PHP process terminates → **All objects are destroyed**.  

6. Next request starts from a completely clean state.

**Complete Lifecycle Code Example:**

```php
// app/Providers/AppServiceProvider.php
namespace App\Providers;

use App\Services\Store;
use Illuminate\Support\ServiceProvider;
use Illuminate\Support\Facades\Log;

class AppServiceProvider extends ServiceProvider
{
    public function register()
    {
        Log::info('[register] Called - Defining blueprints');
        
        $this->app->singleton('store', function ($app) {
            Log::info('[singleton closure] Store created lazily');
            return new Store();
        });
    }
    
    public function boot()
    {
        Log::info('[boot] Called - Creating live objects');
        
        $store = new Store();
        $store->set('boot_time', microtime(true));
        $this->app->instance(Store::class, $store);
    }
}

// routes/web.php
Route::get('/lifecycle', function () {
    Log::info('[route] Handling /lifecycle request');
    
    $store = app(Store::class);
    $store->set('request_count', ($store->get('request_count', 0) + 1));
    
    return response()->json([
        'boot_time' => $store->get('boot_time'),
        'request_count' => $store->get('request_count'),
        'pid' => getmypid(),
    ]);
});

// Log Output:
// [2026-03-28 10:30:00] [register] Called - Defining blueprints
// [2026-03-28 10:30:00] [boot] Called - Creating live objects
// [2026-03-28 10:30:01] [route] Handling /lifecycle request
// [2026-03-28 10:30:02] [route] Handling /lifecycle request  <- Fresh PHP process!
```

#### Comparison Table – Standard Laravel (PHP-FPM)

| Feature                  | `register()` + `singleton`          | `boot()` + `instance`                  |

|--------------------------|-------------------------------------|----------------------------------------|

| Instantiation            | Lazy (on-demand)                    | Eager (every request)                  |

| Logic                    | Closure-based                       | Direct object creation                 |

| Data Persistence         | Lost after request                  | Lost after request                     |

| Performance Impact       | Better (no creation if unused)      | Slightly heavier (always created)      |

---

### 3. Service Binding Behavior in Laravel Octane

In **Laravel Octane**, the application remains alive in memory across thousands of requests. This fundamentally changes how bindings behave.

#### 1. `register()` + `singleton` (Lazy & Persistent)

- The closure runs **only once** — on the first request that resolves the binding.  

- The resulting object is stored in the worker’s memory and reused for all subsequent requests on that worker.  

- **Risk**: This commonly causes **data leaks** between different users.

```php
// app/Providers/AppServiceProvider.php
namespace App\Providers;

use App\Services\Store;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function register()
    {
        // DANGEROUS: Same singleton reused across requests
        $this->app->singleton('store', fn() => new Store());
    }
}

// routes/web.php
Route::post('/login', function (Request $request) {
    $user = auth()->user();
    
    // Request 1 (User A)
    app('store')->set('current_user', $user->id);
    app('store')->set('user_email', $user->email);
    
    return response()->json(['login' => 'success']);
});

Route::get('/profile', function () {
    // Request 2 (User B on same worker)
    $store = app('store');
    
    dump($store->all());
    // Output: [
    //     'current_user' => 1,     // SHOULD BE: 2 (User B)
    //     'user_email' => 'user_a@example.com'  // SHOULD BE: user_b@example.com
    // ]  → DATA LEAK! User B sees User A's data!
});
```

#### 2. `boot()` + `instance` (Eager & Permanent)

- The `boot()` method typically runs **only once** when the Octane worker starts.  

- The object becomes a **global shared instance** for the entire lifetime of that worker.  

- **Risk**: Acts like a global variable — data persists indefinitely until the worker is restarted.

```php
// app/Providers/AppServiceProvider.php
namespace App\Providers;

use App\Services\Store;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function boot()
    {
        // DANGEROUS: Global singleton created at worker startup
        $store = new Store();
        $store->set('shared_cache', []);
        $this->app->instance('store', $store);
    }
}

// routes/web.php
Route::get('/cache-test', function () {
    $store = app('store');
    $cache = $store->get('shared_cache', []);
    $cache[] = auth()->id() ?? 'anonymous';
    $store->set('shared_cache', $cache);
    
    return response()->json(['cache' => $cache]);
});

// Octane: php artisan octane:start --workers=1
// Request 1 (User 1): GET /cache-test  → Output: {"cache": [1]}
// Request 2 (User 2): GET /cache-test  → Output: {"cache": [1, 2]}
// Request 3 (User 1): GET /cache-test  → Output: {"cache": [1, 2, 1]}
// The cache NEVER clears until worker restarts → MEMORY LEAK!
```

#### Comparison Table – Laravel Octane

| Feature               | `register()` + `singleton`               | `boot()` + `instance`                    |

|-----------------------|------------------------------------------|------------------------------------------|

| Creation Timing       | On first request that needs it           | Once when the worker starts              |

| Data Persistence      | Persists across requests (leak risk)     | Persists across requests (leak risk)     |

| Memory Usage          | Only if actually used                    | Used immediately at worker startup       |

| Automatic Reset       | None                                     | None                                     |

---

### 4. The "Worker Island" Effect

Octane runs multiple identical **Workers** (separate PHP processes). Each worker maintains its own private memory space.

- A load balancer distributes requests across workers.  

- One worker cannot see data stored in another worker.  

- This makes both `singleton` and `instance` **unpredictable** across requests.

**Result**: Users may see different data depending on which worker handles their request.

---

### 5. The Correct Solution: `scoped()`

Laravel introduced the `scoped()` binding specifically for long-lived applications like Octane.

- Behaves like a `singleton` **within a single request**.  

- Octane **automatically destroys** the instance when the request ends.

```php

// AppServiceProvider.php

public function register()

{

    $this->app->scoped('store', function ($app) {

        return new Store();

    });

}

```

#### Final Binding Comparison (Octane)

| Method       | Behavior in Octane                          | Safety      |

|--------------|---------------------------------------------|-------------|

| `bind`       | New instance every resolution               | **Safe**    |

| `singleton`  | Shared across requests on same worker       | **Dangerous** (data leak) |

| `instance`   | Shared across requests on same worker       | **Dangerous** (data leak) |

| `scoped`     | One instance per request, auto-destroyed    | **Perfect** (matches PHP-FPM behavior) |

**Key Recommendation:**  

> Never use `singleton` or `instance` for classes that hold user-specific or request-specific data in Octane. Always prefer `scoped()` to ensure clean memory between requests.

---

### 6. Stale App vs Fresh Sandbox App Issue

When registering services in Octane, it is **critical** to use the `$app` parameter passed into the closure instead of `$this->app`.

#### Incorrect (Stale Master App)

```php

// Captures the original master Application instance

$this->app->bind('service', function () {

    return new Service($this->app);

});

```

#### Correct (Fresh Sandbox App)

```php

// Uses the sandboxed Application instance for the current request

$this->app->bind('service', function ($app) {

    return new Service($app);

});

```

#### Why It Matters

- `$this->app` → References the **Master Application** (static since worker boot).  

- `$app` from closure → References the **current request’s Sandbox Application**.

**Consequence**: Using the Master App can lead to stale configuration, incorrect request data, or 404 errors.

#### Summary Table

| Code Syntax                     | App Instance Used     | Octane Behavior                  |
|---------------------------------|-----------------------|----------------------------------|
| `new Service($this->app)`       | Master App            | Static → Potential bugs          |
| `new Service($app)`             | Sandbox App           | Dynamic & safe per request       |

---

### 7. Using `Container::getInstance()` for Safe Sandboxing

`Container::getInstance()` (or the `app()` helper) is often the **safest and most modern** approach for accessing the current application instance in Octane.

It always returns the **currently active** container, automatically following the sandbox for each request.

#### Recommended Pattern (Lazy Resolution)

```php
// app/Services/DatabaseService.php
namespace App\Services;

use Illuminate\Container\Container;

class DatabaseService
{
    protected $appResolver;
    protected $connection;

    public function __construct(callable $appResolver)
    {
        $this->appResolver = $appResolver;
    }

    public function getConnection()
    {
        $app = ($this->appResolver)();
        
        // Always gets the correct sandboxed app
        return $app->make('db');
    }
    
    public function getAppId(): string
    {
        $app = ($this->appResolver)();
        return spl_object_hash($app);
    }
    
    public function query(string $sql)
    {
        return $this->getConnection()->statement($sql);
    }
}

// app/Providers/AppServiceProvider.php
namespace App\Providers;

use App\Services\DatabaseService;
use Illuminate\Container\Container;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function register()
    {
        // Safe pattern: Pass resolver closure instead of direct $this->app
        $this->app->singleton(DatabaseService::class, function () {
            return new DatabaseService(
                fn() => Container::getInstance()
            );
        });
    }
}

// routes/web.php
Route::get('/db-test', function () {
    $dbService = app(DatabaseService::class);
    
    return response()->json([
        'app_id' => $dbService->getAppId(),
        'pid' => getmypid(),
        'memory' => memory_get_usage(true),
    ]);
});

// Output (Octane with multiple requests):
// Request 1: {"app_id": "00000001", "pid": 1234, "memory": 2097152}
// Request 2: {"app_id": "00000002", "pid": 1234, "memory": 2097152}  <- Different app_id!
// Different sandbox app for each request = Safe!
```

#### Comparison Table

| Method                            | Result in Octane | Explanation |
|-----------------------------------|------------------|-----------|
| `new Service($this->app)`         | Different        | Holds permanent Master App reference |
| `new Service($app)`               | Same*            | Uses Sandbox (when resolved during request) |
| `Container::getInstance()`        | Same             | Always resolves current active container |

> **Important**: Even with correct sandboxing, `singleton` can still cause data leaks. Combine this technique with `scoped()` for complete safety.

---

### 8. Advanced Octane Features: Task Workers, Ticks & Cache

#### 8.1 Task Workers – Parallel Heavy Processing

Octane provides **Web Workers** (handle HTTP) and **Task Workers** (handle heavy operations) to prevent blocking.

**Configuration & Complete Example:**

```bash
# Terminal: Start Octane with 4 web workers and 8 task workers
php artisan octane:start --server=swoole --workers=4 --task-workers=8
```

```php
// app/Http/Controllers/ReportController.php
namespace App\Http\Controllers;

use App\Models\User;
use App\Models\Order;
use Laravel\Octane\Facades\Octane;
use Illuminate\Http\Request;

class ReportController extends Controller
{
    // BLOCKING approach (BAD - holds worker)
    public function generateReportBlocking()
    {
        $users = User::where('active', true)
            ->with('orders', 'profile')
            ->get(); // 5 seconds
        
        $orders = Order::whereYear('created_at', 2026)
            ->with('customer', 'items')
            ->get(); // 3 seconds
        
        // Total: 8 seconds blocked!
        return view('report', compact('users', 'orders'));
    }
    
    // CONCURRENT approach (GOOD - parallel, non-blocking)
    public function generateReportConcurrent()
    {
        [$users, $orders] = Octane::concurrently([
            fn() => User::where('active', true)
                ->with('orders', 'profile')
                ->get(),  // Runs in parallel
            
            fn() => Order::whereYear('created_at', 2026)
                ->with('customer', 'items')
                ->get(),  // Runs in parallel
        ]);
        
        // Total: ~5 seconds (max of both, not sum!)
        return view('report', compact('users', 'orders'));
    }
    
    // HEAVY TASK delegation (BEST - offloads to task workers)
    public function generateReportAsync()
    {
        Octane::task(function () {
            // Runs in a task worker, doesn't block web worker
            $report = [
                'users' => User::where('active', true)->get(),
                'orders' => Order::whereYear('created_at', 2026)->get(),
                'generated_at' => now(),
            ];
            
            // Store in cache or database for later retrieval
            cache()->put('report_' . auth()->id(), $report, now()->addHour());
        });
        
        return response()->json(['status' => 'Report generation started in background']);
    }
    
    public function getReportStatus()
    {
        $report = cache()->get('report_' . auth()->id());
        
        return response()->json([
            'status' => $report ? 'ready' : 'processing',
            'data' => $report,
        ]);
    }
}

// routes/web.php
Route::get('/report/blocking', [ReportController::class, 'generateReportBlocking']);     // Blocks web worker
Route::get('/report/concurrent', [ReportController::class, 'generateReportConcurrent']); // Faster, still on web worker
Route::post('/report/async', [ReportController::class, 'generateReportAsync']);          // Best: offloads
Route::get('/report/status', [ReportController::class, 'getReportStatus']);             // Poll for result
```

#### 8.2 Octane Ticks – In-Memory Recurring Tasks

Ticks replace traditional cron jobs with zero boot overhead.

```php
// app/Providers/AppServiceProvider.php
namespace App\Providers;

use Illuminate\Support\ServiceProvider;
use Laravel\Octane\Facades\Octane;
use Illuminate\Support\Facades\Cache;
use App\Models\User;
use App\Models\Order;

class AppServiceProvider extends ServiceProvider
{
    public function boot()
    {
        // Tick 1: Refresh user statistics every 5 seconds
        Octane::tick('refresh-stats', function () {
            $userCount = User::count();
            $activeUsers = User::where('last_seen', '>', now()->subHours(24))->count();
            
            Cache::store('octane')->put('user_count', $userCount);
            Cache::store('octane')->put('active_users', $activeUsers);
            
            \Log::info('Stats refreshed', [
                'users' => $userCount,
                'active' => $activeUsers,
            ]);
        })->seconds(5);
        
        // Tick 2: Clean up old sessions every 30 seconds
        Octane::tick('cleanup-sessions', function () {
            $deleted = \DB::table('sessions')
                ->where('last_activity', '<', now()->subHours(24)->getTimestamp())
                ->delete();
            
            if ($deleted > 0) {
                \Log::info('Cleaned up ' . $deleted . ' old sessions');
            }
        })->seconds(30);
        
        // Tick 3: Generate hourly report
        Octane::tick('hourly-report', function () {
            $report = [
                'total_orders' => Order::count(),
                'revenue_today' => Order::whereDate('created_at', today())->sum('total'),
                'avg_order_value' => Order::whereDate('created_at', today())->avg('total'),
                'timestamp' => now(),
            ];
            
            Cache::store('octane')->put('hourly_report', $report);
            \Log::info('Hourly report generated', $report);
        })->seconds(3600); // Every hour
    }
}

// routes/web.php
Route::get('/stats', function () {
    return response()->json([
        'users' => cache()->store('octane')->get('user_count', 0),
        'active' => cache()->store('octane')->get('active_users', 0),
        'hourly_report' => cache()->store('octane')->get('hourly_report'),
    ]);
});

// Benefits:
// - No cron configuration needed
// - Zero bootstrap overhead (tasks run in-memory)
// - Ticks are per-worker (so data can be worker-specific or shared via cache store)
// - Perfect for frequent, lightweight operations
```

#### 8.3 Octane Cache with Intervals

The `octane` cache driver uses Swoole Tables (shared RAM) for extreme performance (2M+ ops/sec).

**Configuration & Complete Example:**

```php
// config/cache.php
return [
    'default' => env('CACHE_DRIVER', 'octane'),
    
    'stores' => [
        'octane' => [
            'driver' => 'octane',
            'tables' => [
                'cache' => [
                    'size' => 65536,  // Number of key-value pairs
                    'conflict_resolution' => 'CRC32', // Conflict resolution strategy
                ],
            ],
        ],
        'redis' => [
            'driver' => 'redis',
            'connection' => 'default',
        ],
        'database' => [
            'driver' => 'database',
            'table' => 'cache',
            'connection' => null,
        ],
    ],
];

// app/Http/Controllers/LeaderboardController.php
namespace App\Http\Controllers;

use Illuminate\Support\Facades\Cache;
use App\Models\User;

class LeaderboardController extends Controller
{
    // Interval: Auto-refresh cached data every 10 seconds
    public function topUsers()
    {
        $users = Cache::store('octane')
            ->interval('top_users', function () {
                return User::orderBy('points', 'desc')
                    ->select('id', 'name', 'email', 'points')
                    ->limit(10)
                    ->get()
                    ->toArray();
            }, seconds: 10);
        
        return response()->json([
            'leaderboard' => $users,
            'cached_at' => now(),
        ]);
    }
    
    // Direct cache get/put for hot data
    public function siteStats()
    {
        // Try to get from octane cache (2M+ ops/sec)
        $stats = Cache::store('octane')->get('site_stats');
        
        // If not cached, compute and store
        if (!$stats) {
            $stats = [
                'total_users' => User::count(),
                'active_today' => User::where('last_seen', '>', now()->subHours(24))->count(),
                'avg_score' => User::avg('points'),
                'computed_at' => now(),
            ];
            
            Cache::store('octane')->put('site_stats', $stats, now()->addMinute());
        }
        
        return response()->json($stats);
    }
    
    // Clear cache when data changes
    public function updateProfile(Request $request)
    {
        $user = auth()->user();
        $user->update($request->validated());
        
        // Invalidate related cache entries
        Cache::store('octane')->forget('top_users');
        Cache::store('octane')->forget('site_stats');
        
        return response()->json(['status' => 'updated']);
    }
}

// routes/web.php
Route::get('/leaderboard', [LeaderboardController::class, 'topUsers']);       // Auto-refresh every 10 seconds
Route::get('/stats', [LeaderboardController::class, 'siteStats']);            // Manual caching
Route::post('/profile', [LeaderboardController::class, 'updateProfile']);     // Invalidate cache on update

// Performance comparison:
// - Database query: 50ms
// - Redis get: 1-5ms
// - Octane cache get: 0.0005ms (100x faster than Redis!)
// With 1000 req/sec: 50 seconds vs 5 seconds vs 0.5 seconds
```

#### Feature Summary Table

| Feature           | Best Use Case                          | Key Benefit |
|-------------------|----------------------------------------|-----------|
| **Task Workers**  | Heavy DB queries, parallel tasks       | Non-blocking for end users |
| **Ticks**         | Recurring lightweight tasks            | Replaces cron with zero overhead |
| **Octane Cache**  | Global hot data (settings, counters)   | 2M+ ops/sec in shared RAM |
| **Intervals**     | Self-refreshing cached data            | Automatic freshness without extra logic |

---

**Final Production-Ready Implementation Example:**

```php
// app/Providers/AppServiceProvider.php - CORRECT PATTERNS
namespace App\Providers;

use App\Services\Store;
use App\Services\UserRepository;
use Laravel\Octane\Facades\Octane;
use Illuminate\Support\Facades\Cache;
use Illuminate\Container\Container;
use Illuminate\Support\ServiceProvider;
use App\Models\User;

class AppServiceProvider extends ServiceProvider
{
    public function register()
    {
        // ✅ SAFE: Scoped for request-specific data
        $this->app->scoped(Store::class, function ($app) {
            return new Store();
        });
        
        // ✅ SAFE: Repository with lazy app resolution
        $this->app->singleton(UserRepository::class, function () {
            return new UserRepository(
                fn() => Container::getInstance()
            );
        });
    }
    
    public function boot()
    {
        // ⚠️ OK for read-only global config (no user data)
        $this->app->instance('feature_flags', [
            'new_dashboard' => env('FEATURE_NEW_DASHBOARD', false),
            'beta_api' => env('FEATURE_BETA_API', false),
        ]);
        
        // Octane Ticks: Refresh global data
        Octane::tick('refresh-config', function () {
            $flags = cache()->get('feature_flags', []);
            app()->instance('feature_flags', $flags);
        })->seconds(30);
    }
}

// routes/web.php
Route::middleware(['web'])->group(function () {
    // ✅ SAFE: Each request gets its own Store instance
    Route::get('/user/data', function () {
        $store = app(Store::class);
        $store->set('user', auth()->user());
        
        return response()->json([
            'user' => $store->get('user'),
            'app_id' => spl_object_hash(app()),
        ]);
    });
    
    // ✅ SAFE: Uses scoped container
    Route::post('/store/item', function (Request $request) {
        $store = app(Store::class);
        $store->set('item', $request->validated());
        
        return response()->json(['stored' => true]);
    });
    
    // ✅ SAFE: Cached leaderboard with intervals
    Route::get('/leaderboard', function () {
        $top = Cache::store('octane')
            ->interval('top_10_users', function () {
                return User::orderBy('score', 'desc')
                    ->limit(10)
                    ->get(['id', 'name', 'score']);
            }, seconds: 60);
        
        return response()->json(['leaderboard' => $top]);
    });
});

// Artisan commands for testing
// php artisan octane:start --server=swoole --workers=4 --task-workers=2
// curl http://localhost:8000/user/data
```

**Final Recommendation for Octane Development:**

✅ **DO:**
- Use **`scoped()`** for any request-scoped or user-specific services.  
- Use **`singleton()`** only for stateless utilities (logging, config readers).  
- Use the injected `$app` parameter or `Container::getInstance()` inside closures.  
- Leverage **Task Workers** for heavy operations (5+ seconds).  
- Use **Ticks** for lightweight recurring tasks (< 1 second).  
- Use **Octane Cache** for hot, read-heavy data (shared across workers via Swoole Tables).  
- Use **Sessions with Redis/Database** for user state (shared across workers).  
- **Monitor memory** — Octane keeps everything in RAM, so memory leaks will bloat with time.

❌ **DON'T:**
- Never use `singleton` or `instance` for stateful, user-specific data.  
- Never store `$this->app` directly — always pass the closure `$app` parameter.  
- Never put unbounded arrays in memory (e.g., accumulating logs, user sessions).  
- Never assume workers share memory — design for the multi-worker "island" model.  
- Never forget that Ticks run on every worker independently (design for idempotence).

These patterns will help you build **stable, predictable, and high-performance** applications with Laravel Octane.


### Sessions already solve the problem of **persisting user-specific data across requests** — so why introduce all the complexity of Octane (workers, sandboxing, scoped bindings, memory management, etc.)?

Here's a clear, professional breakdown:

### 1. Sessions and Octane Solve Completely Different Problems

| Purpose                        | Laravel Sessions                              | Laravel Octane                                      |
|--------------------------------|-----------------------------------------------|-----------------------------------------------------|
| **What it persists**           | **User-specific** data (cart, preferences, auth flash messages, etc.) | **Application-level performance** and shared resources |
| **Storage**                    | Backend (Redis, Database, file, etc.) — shared across all servers/workers | In-memory (RAM) within each worker + optional shared drivers |
| **Scope**                      | Tied to a specific user/session ID            | Affects the entire application (framework boot, DB connections, services) |
| **Lifetime**                   | Until session expires or is destroyed         | Until the Octane worker is restarted                |
| **Main Goal**                  | Maintain state for one user across requests   | Make every request dramatically faster              |

**Sessions are for user data.**  
**Octane is for speed and resource efficiency.**

You still use **sessions exactly the same way** in Octane (preferably with Redis or Database driver for multi-worker setups). Octane does **not** replace sessions.

### 2. Why Octane Makes Sense (Even With Sessions Available)

Sessions help with **what** to remember for a user.  
Octane helps with **how fast** your entire app can respond to every request.

Key performance wins from Octane:

- **No repeated bootstrapping** — In traditional PHP-FPM, Laravel boots the entire framework (service providers, config loading, container setup, etc.) on **every single request**. Octane boots once when the worker starts and keeps everything warm in memory.
- **Persistent database connections** — No overhead of connecting to the DB on every request.
- **Extremely fast in-memory operations** — Especially with the `octane` cache driver (powered by Swoole Tables) — up to **2 million operations per second**.
- **Concurrent task handling** — Using `Octane::concurrently()` or Task Workers to run heavy work without blocking the user.
- **Ticks** — Lightweight recurring tasks (stats, cleanup) without needing cron jobs that re-boot Laravel every time.
- **Overall throughput** — Real-world benchmarks often show **2x–10x+** more requests per second and much lower latency, especially under load.

In short: Even if your app uses sessions perfectly, every request is still paying the full cost of booting Laravel unless you use Octane (or similar long-running servers).

### 3. When Octane Feels "Over-Complicated"

You're right that Octane **does** add complexity:
- You must be careful with `singleton` vs `scoped` bindings (as we discussed earlier).
- You need to avoid accidental memory leaks from static variables or shared objects.
- With multiple workers, in-memory data (like a naive singleton store) becomes unpredictable ("Worker Island" effect).
- Sessions should use a shared backend (Redis/Database) instead of file driver when scaling.

This is why many teams start with **traditional PHP-FPM** and only move to Octane when they hit performance bottlenecks or want to handle significantly higher traffic with fewer servers.

### 4. Simple Rule of Thumb

- **Use Sessions** for anything that belongs to a **specific user** (shopping cart, user preferences, form data, flash messages, etc.).
- **Use Octane** when you want your app to be **blazing fast** and handle high concurrency efficiently.
- **Use Octane Cache + Intervals** for global/hot data that many users need quickly (e.g., site settings, leaderboards, counters).
- **Use scoped()** in Octane for any request-specific services so they behave like they do in normal Laravel.

### Final Thought

Sessions and Octane are **complementary**, not alternatives.

You can (and usually should) use both together:
- Sessions (Redis) → for user state
- Octane → for raw speed and efficient resource usage

The "complication" comes from the fact that Octane turns your app from **stateless per-request** (PHP-FPM style) into a **semi-stateful long-running process**. Once you adopt the right patterns (`scoped()`, proper cache drivers, avoiding global state leaks), the performance gains are often worth it for medium-to-high traffic applications.



### **Eloquent model `boot()`** (and `booted()`) when using **Laravel Octane**.

### Short Answer
It does **not** behave the same way as Service Provider `boot()` in Octane.

The `protected static function boot()` method in your Eloquent models (**`CreditNote`** extending **`Voucher`**) is **safe and efficient** even in Octane. It does **not** cause performance issues.

### Detailed Explanation

#### 1. How Eloquent `boot()` Actually Works (in both PHP-FPM and Octane)

- The `boot()` method (and the newer `booted()` method) is a **static** method on the Model class.
- Laravel calls it **lazily** — the first time the model class is actually used (e.g., when you do `CreditNote::query()`, `new CreditNote()`, `CreditNote::find()`, etc.).
- Inside `boot()`, things like `static::addGlobalScope()` and `static::creating()` event listeners are registered **once per model class per worker**.
- Once registered, the global scope and model events stay active for the lifetime of that PHP process/worker.

This is **by design** and is exactly what you want.

#### 2. Behavior in Laravel Octane (Important Differences)

| Aspect                        | Traditional PHP-FPM                          | Laravel Octane (Swoole/RoadRunner)                     |
|-------------------------------|----------------------------------------------|-------------------------------------------------------|
| When `boot()` runs            | On every request (first time model is used) | **Only once per worker** (when model is first used after worker starts) |
| Global Scope registration     | Happens every request                        | Happens once per worker                               |
| `static::creating()` listener | Registered every request                     | Registered once per worker                            |
| Performance impact            | Tiny (but repeated)                          | **Much better** — no repeated registration            |
| Risk of issues                | Almost none                                  | Very low (if you follow best practices)               |

**Key Point:**  
In Octane, the model class is loaded and booted **once per Octane worker**. After that, the global scope (`CreditNoteScope`) and the `creating` event listener remain registered in memory for all future requests handled by that worker.

This is **more efficient**, not less.

### Is It Making Performance Inefficient?

**No — quite the opposite.**

- Registering a global scope or model event is a very lightweight operation (just adding something to an internal array on the model).
- Doing it only **once per worker** (instead of on every request) is actually a small performance **win** in Octane.
- The real cost in models is usually elsewhere: database queries, relationships, attribute casting, etc.

Your current code is perfectly fine:

```php
protected static function boot()
{
    parent::boot();

    static::addGlobalScope(new CreditNoteScope);

    static::creating(function ($model) {
        $model->type = self::TYPE;
    });
}
```

**Recommendation (Modern Laravel style):**  
Many developers now prefer `booted()` over `boot()` because it runs after the parent has fully booted:

```php
protected static function booted()
{
    static::addGlobalScope(new CreditNoteScope);

    static::creating(function ($model) {
        $model->type = self::TYPE;
    });
}
```

Both are acceptable.

### When You Need to Be Careful in Octane

You only run into problems if your global scope or model event does something **dangerous** like:

- Storing request-specific data in a static property.
- Capturing the current `Request` or `Auth` user permanently inside the scope.
- Performing heavy operations (e.g., database calls) inside the `boot()` / `booted()` method itself.

**Good practice for scopes in Octane:**

```php
// In your CreditNoteScope.php
public function apply(Builder $builder, Model $model): void
{
    // This runs on EVERY query — keep it fast and stateless
    $builder->where('type', CreditNote::TYPE);
    
    // If you need current user/tenant, resolve it fresh every time
    if (auth()->check()) {
        $builder->where('user_id', auth()->id());
    }
}
```

Avoid putting heavy logic or closures that capture stale state inside `boot()`.

### Summary for Your Notes

- **Model `boot()` / `booted()`** → Runs **once per worker** in Octane (very efficient).
- **Global scopes and model events** registered here are meant to live for the lifetime of the worker.
- This is **safe and performant** for most cases.
- Your `CreditNote` / `Voucher` inheritance with `static::TYPE` is a common and acceptable pattern.
- Only be careful if the scope itself holds mutable state or depends on request data — always resolve fresh data inside `apply()`.

