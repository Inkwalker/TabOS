# .tap apps

A `.tap` bundle contains `app.lua` and an optional `lib/` directory for modules. Copy it to the SD card, tap **Refresh**, then tap its launcher icon.

In recovery, enter the bundle path, such as `/sd/hello.tap`. Quote paths and arguments containing spaces. Arguments reach `app.lua` as strings in `...`.

## Launcher manifest

Add `manifest.ltab` to the bundle:

```lua
{
    name = "My App",
    icon = "icon.png",
}
```

| Field | Rules | Fallback |
| --- | --- | --- |
| `name` | Display name for labels, menus, and sorting. | Directory name without `.tap`. |
| `icon` | Bundle-relative PNG path using `/`; no absolute paths or `..` segments. | Built-in initial icon if missing, invalid, oversized, or unloadable. |

Use opaque, 28 × 28 pixel icons. Smaller images are centered; transparency is flattened against black. App scans, including **Refresh**, reload manifests and icons. Recovery launches apps by path.

## Runtime and modules

Each launch gets fresh globals, an app-local module cache, and an `os` table, plus shared APIs such as `gfx`, `input`, and `fs`.

`require("tools.format")` searches `lib/tools/format.lua`, then `lib/tools/format/init.lua`. Results are cached in `package.loaded` for that launch (`nil` becomes `true`); circular imports raise an error.

| API | Behavior |
| --- | --- |
| `os.path(path)` | Resolve a bundle-relative path and normalize `.` and `..`. Preserve absolute paths; an empty path returns the bundle path. |
| `os.exit()` | Close after the current callback; overrides suspension. |
| `os.suspend()` | Suspend after the current callback succeeds. |

Use `os.path("spr/ball.png")` to locate bundled assets.

## Lifecycle hooks

Define hooks as global functions. All are optional; only `save_state()` return values are used.

| Hook | Behavior |
| --- | --- |
| `init(state, explicit_args)` | Run after `app.lua` unless exit or suspension was requested. `state` is the saved table on resume, otherwise `nil`; `explicit_args` indicates new launch arguments. |
| `update(dt)` | Run at a target of 60 Hz; `dt` is elapsed seconds. Without this hook, the app closes after initialization. |
| `save_state()` | On suspension, return a plain table or `nil`. Returning `nil, message` or an invalid payload, or raising an error, cancels suspension. |
| `deinit(reason)` | Run once on close with `"exit"`, `"forced"` (**Ctrl+Esc**), `"error"`, or `"suspend"`. Cleanup errors are reported. |

The shell polls input and blocks keys and touches held across transitions until release. Call `gfx.flip()` to present each frame.

## Suspension and resume

Suspension keeps one RAM session per normalized, case-insensitive bundle path until restart, even without a `save_state()` hook or payload. Exit, **Ctrl+Esc**, and callback errors skip state saving.

Snapshots use strings, numbers, booleans, and plain tables as keys and values. The runner checks the root table for a metatable and retains the snapshot by reference; treat it as read-only during cleanup and restoration.

Relaunching a bundle reloads its code and resumes its session, reusing saved arguments unless new ones are supplied. Successful initialization consumes the session; load or initialization errors preserve it for retry.

Suspended apps show a pause badge. Hold an icon and confirm **Forget Session** to discard its RAM session.

Custom shells can use:

| Runner method | Purpose |
| --- | --- |
| `runner:suspend()` | Request suspension. |
| `runner:has_session(path)` | Check for a session. |
| `runner:session(path)` | Read a session. |
| `runner:forget(path)` | Discard a session. |

See the [suspension specification](specs/app-suspension.md) for details and [Bricks](../apps/bricks.tap/app.lua) for a modular example.
