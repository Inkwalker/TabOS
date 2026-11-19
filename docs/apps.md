# .tap apps

A `.tap` bundle contains `app.lua` and an optional `lib/` directory. Copy it to the SD card and list its absolute path in `/sd/sys/shortcuts.ltab`, for example `{"/sd/apps/files.tap", "/sd/apps/my-app.tap"}`. The desktop fills columns top to bottom in list order and skips duplicates and unavailable bundles. It reloads shortcuts, manifests, and icons at boot and on return to the desktop.

In recovery, enter the bundle path, for example `/sd/hello.tap`. Quote paths and arguments containing spaces. Launch arguments reach `app.lua` as strings in `...`.

## Launcher manifest

Set optional fields in the bundle's `manifest.ltab`.

| Field | Behavior |
| --- | --- |
| `name` | Display name. Defaults to the directory name without `.tap`. |
| `icon` | Bundle-relative PNG path using `/` and no `..` segments. Use an opaque 28 × 28 image. Smaller icons are centered and transparency is flattened against black. Missing, invalid, oversized, or unreadable icons fall back to the app's initial. |
| `window` | `true` gives the app a 300 × 180 canvas and shows the system taskbar. Defaults to `false` (fullscreen). |
| `file_extensions` | File types the app can open, for example `{".lua", ".txt"}`. The file path arrives as the first launch argument. |

## Runtime and modules

Each launch gets fresh globals, its own `os` table and module cache, and shared APIs such as `gfx`, `input`, and `fs`. `require("tools.format")` tries `lib/tools/format.lua`, then `lib/tools/format/init.lua`. Results are cached in `package.loaded` (`nil` becomes `true`). Circular imports raise an error.

| API | Behavior |
| --- | --- |
| `os.path(path)` | Resolve paths such as `"spr/ball.png"` from the bundle, normalizing `.` and `..`. Absolute paths stay absolute. An empty path returns the bundle path. |
| `os.exit()` | Close after the callback. Takes priority over suspension. |
| `os.suspend()` | Suspend after the callback succeeds. |
| `os.open(path, mode)` | After the callback, the graphical shell suspends the caller and opens an absolute path. Use `"with"` to choose a file handler or `"browse"` to browse a bundle directory. |
| `os.refresh_app_registry()` | In the graphical shell, reload associations and discover handlers under `/sd/apps` and at saved handler paths. Returns `true` or `nil, message`. |

For files, the shell uses the saved handler in `/sd/sys/apps.ltab` when configured. Otherwise, it opens the sole match or prompts among several. An unavailable saved handler or zero matches produces an error. Open With always offers the matching apps. A rejected suspension cancels the open request. Open errors and chooser cancellation leave the caller suspended.

## File dialog

```lua
local queued, err = os.file_dialog({mode = "open", directory = "/sd"}, function(path, failure)
    if failure then print(failure) end
    if path then print("Selected " .. path) end
end)
if not queued then print(err) end
```

The graphical shell accepts one request per app callback. Set `mode` to `"open"` or `"save"`. Optional fields are absolute `directory` and `root` paths and a suggested filename `name`. Queueing returns `true` or `nil, message`. Exit, suspension, or callback errors discard the request.

The picker pauses app updates and calls back once with `path, nil` on selection, `nil, nil` on cancellation, or `nil, message` on failure. Escape, Home, and app switches cancel the picker. Home and app switches deliver cancellation before attempting suspension. The caller handles replacement confirmation and writes the file.

The default provider is `picker.lua` in the configured `files_app` bundle. Open browses SD and Recovery by default. Save As selects destinations on SD. Code limits browsing to `/sd` for Open (**Ctrl+O**), Save As (**Ctrl+Alt+S**), and the first save of an untitled tab.

To override the provider, set `dialogs = {file = "/sd/apps/my-picker.tap/picker.lua"}` in `/sd/sys/config.ltab`. The script exports `new(request, context)`, which returns a picker with `update(dt)`, `draw()`, and `close()` methods. Return nothing from `update` while waiting or `true, path, error` to finish. Draw only in `draw()`. The context supplies gated `input`, shell `colors`, and dialog `width` and `height`. The script has private globals and bundle-local `os.path()` and `require()`.

On device, deploy the updated SD shell and copy `app_runner.lua` and `bundle_require.lua` from `recovery_files/sys/` to `/sd/sys/`, or use an updated recovery image for the runner files. Copy the updated `files.tap` and `code.tap` to `/sd/apps/`.

## Lifecycle hooks

Hooks are optional global functions. Only `save_state()` returns a result the runner uses.

| Hook | Behavior |
| --- | --- |
| `init(state, explicit_args)` | Runs after `app.lua` unless it requests exit or suspension. Receives saved state or `nil` and a boolean indicating whether new arguments were supplied. |
| `update(dt)` | Targets 30 Hz. `dt` is elapsed seconds. Omit this hook for an app that closes after initialization. |
| `save_state()` | Return a plain table or `nil` on suspension. `nil, message`, an invalid result, or an error cancels suspension. |
| `deinit(reason)` | Runs once on close with `"exit"`, `"forced"` (**Ctrl+Esc**), `"error"`, or `"suspend"`. The runner reports cleanup errors. |

The SD shell sets the canvas before loading `app.lua` and calls `gfx.flip()` after app and shell drawing. Pixels persist between updates and clipping resets after presentation. The shell blocks keys and touches held across transitions until release.

## Suspension and resume

The runner keeps one RAM session per normalized, case-insensitive bundle path until restart, even without a snapshot. Exit, **Ctrl+Esc**, and callback errors skip state saving. Use strings, numbers, booleans, and plain tables in snapshots. Treat the snapshot as read-only during cleanup and restore because the runner stores it by reference.

Relaunching reloads the app and reuses saved arguments unless new ones are supplied. Successful initialization consumes the session. Load or initialization errors preserve it for retry.

- Tap **Home** to suspend and return to the desktop. If suspension is rejected, the app stays active.
- Tap a suspended taskbar icon to resume it, suspending the current app if needed. Tap `>` to cycle through overflow pages.
- Hold a suspended taskbar icon to discard the session, or hold its desktop shortcut and confirm **Forget Session**.

Custom shells can request, check, read, or discard sessions with `runner:suspend()`, `runner:has_session(path)`, `runner:session(path)`, and `runner:forget(path)`. See [Bricks](../apps/bricks.tap/app.lua) for a modular app example.
