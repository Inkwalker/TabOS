# TabOS Lua API

TabOS installs these global tables before running the boot script.

- [gfx](gfx.md) — draw and present frames
- [input](input.md) — touch, keyboard, and IMU
- [sys](sys.md) — keyboard LEDs, system metrics, and clock
- [fs](fs.md) — filesystem operations
- [audio](audio.md) — wavetable voices
- [.tap apps](apps.md) — directory structure, modules, and lifecycle hooks

## Standard Lua libraries

The firmware opens these libraries before running the boot script.

- Global functions — `assert`, `collectgarbage`, `dofile`, `error`, `getmetatable`, `ipairs`, `load`, `loadfile`, `next`, `pairs`, `pcall`, `print`, `rawequal`, `rawget`, `rawlen`, `rawset`, `select`, `setmetatable`, `tonumber`, `tostring`, `type`, `warn`, `xpcall`

- `package`
- `io`
- `math`
- `string`
- `table`

## System startup hooks

The bundled `/rec/sys/boot.lua` loads `/sd/sys/system.lua`, falling back to
`/rec/sys/system.lua` if the SD script is missing or its top-level chunk fails.
System modules are loaded from the selected `sys` folder.
Holding Del during boot forces recovery.

After the boot script finishes, the firmware uses the system's global hooks:

| Hook | Behavior |
| --- | --- |
| `init()` | Optional; called once after startup loading. |
| `update(dt)` | Optional; called at a target rate of 60 Hz. `dt` is elapsed seconds since the previous tick. Without it, the Lua task ends after initialization. |

Managed [.tap apps](apps.md) have separate hooks dispatched by the recovery shell.
