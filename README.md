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

## Save-load sessions

`UE4SSCommonSession.new(api, directory, report)` creates an inert session manager. The injected `api` contains the Lua environment and UE4SS registration, cancellation and game-thread scheduling functions. `watch(path)` explicitly installs one construction subscription with a bounded replay inbox. `open(file, context)` closes the previous session before loading the entry file into a fresh environment; `pause()` invalidates callbacks and pending activation; `close()` restores owned changes. Call open/close on the game thread. No module import registers hooks or accesses game objects.

The entry file receives `Session` and `SaveLoadContext`. Its local `dofile`/`require` share a fresh per-session module cache, so configuration loaders run once per load. Delayed callbacks and native event dispatch are guarded by session ownership. Native hook/notification dispatchers are reused across loads; closing removes their consumer callbacks without accumulating registrations. Pre/post callback shape must remain consistent for each path. Construction replays contain wrappers only; consumers must defer native access and validate ownership. Notification inboxes keep at most 128 recent objects per path.

`Session.change(key, get, set, value)` skips unchanged values and records an owned scalar baseline before a write. Getters and setters must reacquire borrowed fields from validated owners on every call. Returning `value, false` from a getter skips a dead/replaced field. Keys must identify the owner and field. Setters must support the original value, including absent-map sentinels. Cleanup restores only a value still matching the session's last write, with float tolerance, and verifies the result. Cleanup processes at most 16 scalar restorations within a 0.5 ms soft budget per later 16 ms callback. A setter that rebuilds native state must return true to yield immediately; custom cleanup always yields. Consumers can collect dirty contexts and rebuild each once in onClose callbacks. At most 4096 changed fields are retained. `Session.onClose(callback)` adds bounded cleanup for specialized ownership such as gameplay attributes. Cleanup exceptions withhold new settings and retain failed work for the next load; report functions must not throw.

`new(api, directory, report, {canCleanup=predicate})` optionally suspends cleanup between operations while a consumer's game state is unavailable. The predicate must be a cheap, non-throwing check of owned state. Suspended cleanup retains its cursor without polling or new timers; call `manager.resumeCleanup()` on the relevant completion event. Repeated resumes coalesce. This does not interrupt an operation already running: custom callbacks must recheck their own readiness between native calls that can trigger lifecycle events.

`games/UE4SSDawnwalkerSaveLoad.lua` is an explicit game adapter, bundled under its basename. `start(api, session, entryFile, report, diagnostics, options)` subscribes to save requests, loading completion, player construction and `ClientRestart`. By default, loading notifications are optional for activation: a locally controlled pawn with attributes in the current viewport world can initialize gameplay. Subsequent save requests require completion, a matching restarted controller/pawn, or a new player/world before replacing the snapshot. Ordinary travel and possession retain initialized settings.

Consumers that change gameplay attributes can pass `{requireLoadComplete=true}` as `options`. Initial activation and each requested save then require loading state 0 before readiness work starts. States 1–4 cancel pending readiness; construction and possession cannot bypass this gate. Waiting for completion schedules no worker. If completion events are unavailable, strict activation stays inactive instead of falling back to construction. Consumers must also pause their own deferred activation and gameplay work when loading begins; this option owns only the adapter's readiness worker.

Import/start schedules no worker. Relevant events coalesce into one readiness window: at most 40 game-thread callbacks, first after 16 ms and the remainder 250 ms apart, with at most two service lookups per window. Successful or exhausted windows stop completely; a later lifecycle event can recover. Readiness does not read settings or write game state. The optional mutable `diagnostics` table uses `debugLogging` (default false) and reports the event source, readiness outcome, attempts and aggregate readiness CPU time through `report`. Consumers can update that flag when loading their settings snapshot. Event-registration failures are reported once while independent subscriptions remain usable. Game-specific paths and enum values target Steam build 25232147; this adapter is separate from the generic session and settings store.

The file store remains independent: it performs no lifecycle registration and retains its existing byte format and migration rules. Consumers should keep import code inside their session entry, use the menu as the authoritative settings writer, and avoid startup configuration reads or periodic reconciliation.

For transient UObject values with a zero-argument getter and a single-value setter, use `Session.changeObject(key, owner, getterName, setterName, value)`. It snapshots the object's class and full name and checks that identity and the method's callability before native dispatch. Invalid objects, reused identities and missing getter methods are obsolete restoration entries, so they do not block the replacement session. Available setters and readback remain strict: actual write failures still withhold activation. Object entries cost eight of the sixteen cleanup units, allowing at most two per callback while retaining the 0.5 ms soft budget. No reflected function wrappers or borrowed structs are retained across callbacks. When `api.SaveLoadDiagnostics.debugLogging` is enabled, cleanup reports the aggregate number of skipped object values.

## Bundling and updates

`games/UE4SSDawnwalkerSettings.lua` supplies owned live settings snapshots for Mod Setting Menu 1.0.6+. `new({modId,schema,ids,report,derive})` is inert; `ids` maps the exact menu setting IDs to schema keys. `seed(values)` accepts a complete numeric configuration snapshot without notification. `snapshot()` returns a copy. `start(subscribe)` registers once, including after failure; pass the unmodified menu helper's `subscribe`. `accept(values)` validates a complete menu payload, preserves file-only keys, runs the optional pure `derive`, and notifies only actual changes. `commit(values)` accepts complete values after another authoritative settings writer succeeds. `attach(callback)` replaces the receiver and returns a generation-safe detach function. No API performs file I/O, object discovery, or scheduling. A failed listener cannot undo the menu's completed save.

Sessions may pass `{settings=adapter}` to `new`. Entries receive the latest numeric snapshot in `SaveLoadContext.settings` and install `Session.onSettings(callback)` for live changes. Paused/closed sessions receive no updates; the adapter retains the newest values for the next session. `Session.restart()` schedules a guarded replacement for whole-mod enable/disable only. Ordinary changes should update cached values and wake the consumer's existing bounded worker.

Diagnostics support opt-in `{mutable=true}` and `setEnabled(boolean)`. The stable instance and existing `wrap` callbacks follow the new flag; disabling removes clocks, formatting and counters without changing gameplay subscriptions. Default immutable instances retain the original zero-wrapper disabled behavior.

The menu bridge requires UE4SS `HookProcessConsoleExec=1`. Successful console-handler registration does not prove delivery with a disabled engine hook. Keep the bridge subscription in the persistent mod entry point, outside save-load module caches, and validate actual menu Apply delivery on each supported loader. No console window is required.

`UE4SSCommonSettingsUpgrade.ensure(store, path, schema, defaults, tag)` explicitly adds newly introduced keys to an existing numeric settings file. Call it only at the consumer's configuration boundary after a missing-new-key error. Only keys in `defaults` may be added; malformed values, duplicates and missing older keys still fail. It preserves existing text and preferences, validates the complete schema, verifies a temporary file and retains the original as `settings.ini.before-<tag>`. Occupied backups or concurrent edits stop replacement; failed final renames attempt to restore the original without overwriting a newer file. Keep recovery files if an error is reported. Importing the module performs no I/O, and the unchanged file store remains independently usable.

Copy only required modules under the mod's `Scripts` directory, retaining `SettingsStore.lua` and the `UE4SSCommon` filenames. Include this repository's MIT license in the mod's documentation payload. Use a repository-level `ue4ss-common.lock.json` with `repository`, immutable `commit`, and `modules` entries containing `source`, `sha256` and `destinations`. Destination paths are relative to the consumer checkout.

Updates are explicit: review a new commit, verify its module hashes, replace the declared copies, update the lock, run consumer regressions, and rebuild. A build must reject drift rather than silently refreshing from a branch. Ordinary builds require no network or common-library checkout. Roll back by restoring a previous lock and its matching files. Keep personal settings out of packages.

## Provenance

The initial settings module is the identical MIT implementation used in Controller Tweaks and Remap, Easier Parry and Dodge While Blocking, Fair Duelist, and Quiet Dawn HUD. It includes verified legacy migration cleanup from Controller Tweaks commit `666c7c6e5c12ea2bc9356e9d6386e0219ea95764`. Its SHA-256 is `db597ebcfbe67fd03aa16c3c2eb4129c346975961e4df0481bb70440aa7cfa26`. Generic diagnostics derive from the MIT Quiet Dawn diagnostics implementation and the maintained mods' logging patterns. Retry and hook helpers consolidate bounded-work and registration patterns without importing HUD scheduling or upstream HUD code.
