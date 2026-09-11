# ue4ss-common

Small Lua modules for UE4SS mods: settings storage, opt-in diagnostics, finite readiness retries, and hook bookkeeping. MIT licensed. Each consuming mod bundles an immutable revision; players do not install a separate common mod.

## Requirements and boundaries

Lua 5.4. Settings creation targets Windows. Runtime adapters require the target UE4SS build's `ExecuteInGameThreadWithDelay`, `CancelDelayedAction`, `RegisterHook`, and `UnregisterHook` as applicable. API presence alone does not prove that an engine hook is enabled or delivering callbacks. Validate against the actual game, loader build and configuration.

Modules do not start timers or register hooks when loaded. They do not discover objects, manage HUDs, cache worlds or player objects, or implement gameplay. Each instance belongs to its calling mod; this is shared source, not a cross-mod scheduler or cache. Never call native APIs or game-object methods from an unregistered Lua coroutine. Do not retain borrowed Unreal structs across callbacks.

## SettingsStore

`src/SettingsStore.lua` preserves the numeric Mod Setting Menu storage API:

- `read(path)` returns file text, or `nil, error, code`; input is limited to 1 MiB.
- `parse(text, schema)` returns numeric values or `nil, error`.
- `create(path, text)` creates a new file via a sibling temporary file; existing preferences are never replaced.
- `path(scriptsDirectory)` resolves the mod's `settings.ini`. The scripts directory must include its trailing separator.
- `load(scriptsDirectory, schema, seed)` reads existing settings or calls `seed()` once to create them, returning `values, error, path`.

Schema entries have `key`, `default`, and either `values` (an allowed numeric list) or `min`, `max`, and optional `integer`. All declared keys are required in existing settings. Invalid, duplicate or missing values are rejected. Unknown numeric-setting keys are ignored but duplicate keys remain invalid. A pending `settings.ini.backup` blocks regeneration. Schemas, menu metadata and legacy-import decisions belong to the mod. Generated preferences must never be shipped.

`seed()` may additionally return `values, error, sources`. Each optional source records `path`, captured `text`, and optionally `preservePath`. After this call successfully creates, rereads and validates the settings file, unchanged captured legacy files are removed. Changed inputs, mismatched advanced snapshots, failed creation and concurrent creation retain legacy inputs. Omit `sources` to retain all legacy files. This preserves the consuming mods' existing verified-migration behavior.

## Diagnostics

```lua
local Diagnostics = require('UE4SSCommonDiagnostics')
local D = Diagnostics.new({
    debugLogging = config.debugLogging,
    prefix = '[Example] ',
    output = print,
    clock = os.clock,
    maxEventsPerSecond = 6,
    summarySeconds = 10,
    slowCallbackMs = 2,
})
```

`log(format, ...)` and `error(format, ...)` are always available. `debug(format, ...)`, `event(kind, format, ...)`, `count(key, amount)`, `sample(name, milliseconds)`, `now()`, `snapshot()` and `flush(force)` are opt-in. `event` limits output; `debug` is intended for already-bounded calls. A snapshot owns copies of its counts/timings. Use fixed counter and phase names to bound memory.

`wrap(name, callback)` preserves arguments, nils, multiple results and errors. When diagnostics are disabled it returns the original function, and disabled methods do not read clocks, format or update counters. Guard expensive argument construction at the call site. `onSummary(snapshot)` optionally replaces generic summary rendering; snapshots include `counts`, `timings`, `dropped` and `interval`. Flushes reset summary aggregates. Wrappers check for summaries after outermost activity; there are no reporting timers. Call `flush(true)` explicitly at a bounded completion point when appropriate.

Clock failures or regressions discard timing samples and produce at most one clock warning per instance. Clock resolution, overlapping phases and runtime behavior limit timing precision. These are callback measurements, not engine frame times or FPS. With the default output, messages appear in the UE4SS console/log (`ue4ss/UE4SS.log` in typical installations). Enable the consuming mod's `debugLogging` setting and follow its restart/apply instructions.

## Retry

```lua
local worker = require('UE4SSCommonRetry').new({
    schedule = ExecuteInGameThreadWithDelay,
    cancel = CancelDelayedAction,
    delay = 250,
    limit = 20,
    attempt = function(number)
        return tryApply() and 'done' or 'retry'
    end,
    onComplete = function(reason, attempts) end,
    onError = function(err, attempts) end,
})
worker.wake()
```

`wake()` coalesces requests and does not renew a finished/exhausted budget. `cancel()` invalidates pending work and cancels its native action. `reset()` cancels the old generation and resets its budget without scheduling; call `wake()` after a verified lifecycle event. Both return `true` or `nil, error` if cancellation throws. A native cancellation result of false means the action no longer exists. `status()` returns a plain snapshot with `attempts`, `pending`, `running` and `terminal`.

Attempts return `done`, `retry` or `stop`. Completion reasons are `done`, `stop`, `exhausted` or `error`. An exception or invalid outcome stops the worker and invokes `onError`; ordinary not-ready conditions should return `retry`. Scheduling failure stops and invokes `onError`. Handlers must not throw. The scheduling function must enqueue a later game-thread callback and return a numeric native handle. Repeating-loop return semantics are intentionally not used.

The consumer owns lifecycle events, configuration, readiness checks, owner validation and a bounded cost per attempt. A finite retry count does not make expensive object scans safe. Reset/wake during an attempt supersedes its result without starting overlapping work.

## Hooks

```lua
local hooks = require('UE4SSCommonHooks').new({
    RegisterHook = RegisterHook,
    UnregisterHook = UnregisterHook,
})
local pre, post = hooks.register('input-ready', functionPath, before, after)
if not pre then reportError(post) end
```

`register(key, path, ...)` forwards callback arguments unchanged, including omitted versus explicit nil arguments. It returns both native IDs or `nil, error`. Repeating the identical key/path/callbacks returns existing IDs; a conflicting key is rejected. Keep stable callback references when repeating registration.

`remove(key)` returns true or `nil, error`. `clear()` returns true or `nil, failures`, where each failure has `key` and `error`. Failed cleanup entries remain registered in the bookkeeping and can be retried. A nil native unregister result is success; false or an exception is failure. Non-removable construction/load notifications and their activation guards remain the consumer's responsibility. Successfully receiving IDs does not prove callback delivery. Native and Blueprint pre/post behavior must be chosen and tested by the mod.

## Bundling and updates

Copy only required modules under the mod's `Scripts` directory, retaining `SettingsStore.lua` and the `UE4SSCommon` filenames. Include this repository's MIT license in the mod's documentation payload. Use a repository-level `ue4ss-common.lock.json` with `repository`, immutable `commit`, and `modules` entries containing `source`, `sha256` and `destinations`. Destination paths are relative to the consumer checkout.

Updates are explicit: review a new commit, verify its module hashes, replace the declared copies, update the lock, run consumer regressions, and rebuild. A build must reject drift rather than silently refreshing from a branch. Ordinary builds require no network or common-library checkout. Roll back by restoring a previous lock and its matching files. Keep personal settings out of packages.

## Provenance

The initial settings module is the identical MIT implementation used in Controller Tweaks and Remap, Easier Parry and Dodge While Blocking, Fair Duelist, and Quiet Dawn HUD. It includes verified legacy migration cleanup from Controller Tweaks commit `666c7c6e5c12ea2bc9356e9d6386e0219ea95764`. Its SHA-256 is `db597ebcfbe67fd03aa16c3c2eb4129c346975961e4df0481bb70440aa7cfa26`. Generic diagnostics derive from the MIT Quiet Dawn diagnostics implementation and the maintained mods' logging patterns. Retry and hook helpers consolidate bounded-work and registration patterns without importing HUD scheduling or upstream HUD code.
