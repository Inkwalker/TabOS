# .tap apps

A `.tap` app is a directory, not an archive. No manifest is required.

```text
hello.tap/
  app.lua          # Required entry point
  lib/             # Optional app-local Lua modules
    greeting.lua
    tools/init.lua
```

Copy the directory to the SD card and run `/sd/hello.tap` in the recovery shell.
Relative paths work too; quote paths or arguments containing spaces. Arguments
are passed as strings to the top-level `app.lua` chunk via `...`:

```lua
local name = ...
local greeting = require("greeting") -- lib/greeting.lua

function init()
    gfx.cls()
    gfx.print(10, 10, greeting(name or "world"), gfx.rgb(255, 255, 255))
    gfx.flip()
end

function update(dt)
    if input.keyp(1, 1) then -- Esc
        os.exit()
        return
    end
end
```

For this example, `lib/greeting.lua` returns a function:

```lua
return function(name) return "Hello, " .. name end
```

## Modules and environment

App-local `require("tools")` searches `lib/tools.lua`, then `lib/tools/init.lua`.
Dots become directories: `require("tools.format")` loads `lib/tools/format.lua`
or `lib/tools/format/init.lua`. Imports share the app environment and are cached
per launch in `package.loaded`; a module returning `nil` is cached as `true`.
Circular imports raise an error. This loader does not fall back to system modules
or use `package.path`.

Each launch has its own globals, `_G`, module cache, and `os` table.
The environment inherits system globals, including `gfx`, `sys`, `fs`, and Lua
libraries; shared tables remain shared, so this is not a security sandbox.

The app's `os` table is available in modules and hooks. It provides these
functions instead of the standard Lua `os` library:

| API | Behavior |
| --- | --- |
| `os.exit()` | Request app closure. |
| `os.path(path)` | Resolve a path relative to the app directory, normalizing `.` and `..`. Absolute paths stay absolute; an empty string returns the app directory. |

Pass the resolved path to file APIs:

```lua
local ball = assert(gfx.load_sprite(os.path("spr/ball.png")))
```

Launching does not change the shell's working directory. Paths passed directly
to file APIs are not automatically resolved relative to the app.

## App hooks

Define hooks as global functions in the app environment. All are optional;
present hooks must be functions. The runner ignores their return values.

| Hook | When it runs |
| --- | --- |
| `init()` | Once after `app.lua` finishes, unless exit was already requested. |
| `update(dt)` | Each active shell tick, targeting 60 Hz; `dt` is elapsed seconds. Without this hook, the app closes after initialization. |
| `deinit(reason)` | Once on close: `"exit"` for normal completion, `"forced"` for Ctrl+Esc, or `"error"` for a loading or callback error. |

The shell polls hardware input before app updates; apps do not need to call
`input.update()`. The runner suppresses keys held across app transitions until release.
Apps draw their own frames and call `gfx.flip()` to present them.

Call `os.exit()` to request app closure.
Ctrl+Esc forces app termination.
Cleanup cannot veto exit; cleanup errors are reported and the shell is restored.

See the [system startup hooks](README.md#system-startup-hooks) for custom
systems, and [bricks.tap](../apps/bricks.tap/app.lua) for a modular example.
