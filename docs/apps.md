# .tap apps

A `.tap` app is a directory with an `app.lua` entry point and an optional `lib/` directory for modules. Copy it to the SD card and tap its launcher icon. Use **Refresh** after adding apps.

The recovery shell accepts bundle paths such as `/sd/hello.tap`. Quote paths or arguments containing spaces. Launch arguments reach `app.lua` as strings in `...`.

## Modules and environment

`require("tools.format")` searches `lib/tools/format.lua`, then `lib/tools/format/init.lua`. Results are cached per launch in `package.loaded` (`nil` becomes `true`). Circular imports raise an error.

Each launch creates fresh globals, an app-local module cache, and an `os` table. Apps inherit shared system APIs such as `gfx`, `input`, and `fs`.

| API | Behavior |
| --- | --- |
| `os.exit()` | Close after the current callback. Takes precedence over suspension. |
| `os.suspend()` | Suspend after the current callback returns successfully. |
| `os.path(path)` | Resolve a path relative to the bundle and normalize `.` and `..`. Absolute paths stay absolute. An empty path returns the bundle path. |

Use `os.path("spr/ball.png")` to pass a bundle-relative asset path to file APIs.

## App hooks

Define hooks as optional global functions. Only `save_state()` uses its return values.

| Hook | Behavior |
| --- | --- |
| `init(state, explicit_args)` | Run after `app.lua` unless it requests exit or suspension. Receives the saved table on resume, otherwise `nil`. `explicit_args` is true when this launch supplied arguments. |
| `update(dt)` | Run at a target of 60 Hz with elapsed seconds. Apps without this hook close after initialization. |
| `save_state()` | Return a plain table or `nil` when suspending. Returning `nil, message`, returning an invalid payload, or raising an error keeps the app running. |
| `deinit(reason)` | Run once on close with `"exit"`, `"forced"` (Ctrl+Esc), `"error"`, or `"suspend"`. Cleanup errors are reported. |

The shell polls input and blocks keys and touches held across transitions until release. Call `gfx.flip()` to present a frame.

## Suspension and resume

The shell keeps one session per normalized, case-insensitive bundle path in RAM until restart. A missing `save_state()` hook or a `nil` payload still creates a session. Exit, Ctrl+Esc, and callback errors skip state saving.

Use strings, numbers, booleans, and plain tables for snapshot keys and values. The runner checks the root table for a metatable and retains it by reference. Treat the snapshot as read-only during cleanup and restoration.

Launch the same bundle to resume. The runner reloads its code and reuses saved arguments when no new ones are supplied. Successful initialization consumes the session. A load or initialization error keeps it for retry.

The launcher marks suspended apps with a pause badge. Hold the icon and confirm **Forget Session** to discard the RAM record.

Custom shells can request suspension with `runner:suspend()`, check or read a session with `runner:has_session(path)` or `runner:session(path)`, and discard it with `runner:forget(path)`.

See the [suspension specification](specs/app-suspension.md) for details and [Bricks](../apps/bricks.tap/app.lua) for a modular app example.
