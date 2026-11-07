# TabOS Lua API

TabOS installs these global tables before running the boot script.

- [gfx](gfx.md) — draw and present frames
- [input](input.md) — touch, keyboard, and IMU
- [sys](sys.md) — keyboard LEDs, system metrics, and clock
- [fs](fs.md) — filesystem operations

## Standard Lua libraries

The firmware opens these libraries before running the boot script.

- Global functions — `assert`, `collectgarbage`, `dofile`, `error`, `getmetatable`, `ipairs`, `load`, `loadfile`, `next`, `pairs`, `pcall`, `print`, `rawequal`, `rawget`, `rawlen`, `rawset`, `select`, `setmetatable`, `tonumber`, `tostring`, `type`, `warn`, `xpcall`

- `package`
- `io`
- `math`
- `string`
- `table`

## Startup hooks

The firmware calls an optional global `init()` once after loading the startup script, then calls an optional `update(dt)` at a target rate of 60 Hz. `dt` is elapsed time in seconds since the previous tick.
