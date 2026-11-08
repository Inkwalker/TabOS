# TabOS

Lua-based firmware for the **M5Stack Tab5 (ESP32-P4)**, built with ESP-IDF. Includes a shell, a 320×180 drawing canvas, touch/keyboard/IMU input, SD card storage, and USB MTP file transfer.

## Build and flash

Use an ESP-IDF **5.5.6** environment (the version recorded in `dependencies.lock`) and a Tab5. The Tab5 keyboard is used for the shell.

From an ESP-IDF terminal in this directory:

```sh
idf.py set-target esp32p4
idf.py build
idf.py -p PORT flash
```

Replace `PORT` with your device's serial port. Dependencies are resolved by the ESP-IDF Component Manager. The build also packages `recovery_files/` into the recovery flash partition.

## Running Lua apps

The SD card is mounted at `/sd` and exposed over USB MTP. Copy examples from `apps/` onto the card, then enter their paths in the shell to run them. `.lua` files run as scripts; `.tap` directories launch their `app.lua`. **Ctrl+Esc** force-closes a managed app between callbacks. Enter `help` for shell commands. See [.tap structure and hooks](docs/apps.md).

Use `edit <path>` in recovery to edit or create an ASCII text file on `/sd`, including quoted or relative paths. The editor supports files up to 64 KiB.

At boot, TabOS tries `/sd/system.lua` and falls back to the bundled recovery shell if it is missing or fails to load. Hold **Del** during startup to force recovery.

## Repository

For Lua completion and hover documentation in VS Code, install the recommended
**Lua** extension (`sumneko.lua`) and open this repository folder. Workspace
settings load the editor-only definitions in `tools/lua/` for `gfx`, `input`, `sys`,
`fs`, and `audio`, including sprite methods, waveform choices, and return types.

- `main/` — firmware and Lua bindings.
- `components/` — local keyboard component.
- `recovery_files/` — boot script, recovery shell, commands, and widgets.
- `apps/` — example scripts and apps.
- `docs/` — [Lua API reference](docs/README.md) for `gfx`, `input`, `sys`, `fs`, and `audio`.

## License

[MIT](LICENSE).
