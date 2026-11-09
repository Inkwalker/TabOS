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

The SD card is mounted at `/sd` and exposed over USB MTP. Copy the contents of `apps/` onto the card, including `sys/system.lua`, to use the GUI launcher. It lists `.tap` directories containing `app.lua` across the card as named icons. Tap an icon to launch, use Prev/Next for more apps, and tap Refresh after copying apps. The launcher returns when an app exits or fails. **Ctrl+Esc** force-closes a managed app between callbacks. See [.tap structure and hooks](docs/apps.md).

In the recovery shell, enter app paths to run them. `.lua` files run as scripts; `.tap` directories launch their `app.lua`. Enter `help` for shell commands.

Use `edit <path>` in recovery to edit or create an ASCII text file on `/sd`, including quoted or relative paths. The editor supports files up to 64 KiB.

At boot, TabOS displays `/rec/sys/spr/logo.png` centered on screen, when present, and a recovery hint. It polls the keyboard for 3 seconds before trying `/sd/sys/system.lua`. Press **Del** during this window to force recovery; a short beep confirms detection. It also falls back to `/rec/sys/system.lua` if the SD system is missing or fails to load. System modules are loaded from the selected `sys` folder.

## Repository

For Lua completion and hover documentation in VS Code, install the recommended
**Lua** extension (`sumneko.lua`) and open this repository folder. Workspace
settings load the editor-only definitions in `tools/lua/` for `gfx`, `input`, `sys`,
`fs`, and `audio`, including sprite methods, waveform choices, and return types.

- `main/` — firmware and Lua bindings.
- `components/` — local keyboard component.
- `recovery_files/` — system scripts and widgets in `sys/`, system commands in `sys/bin/`, and the editor app.
- `apps/` — example scripts and apps.
- `docs/` — [Lua API reference](docs/README.md) for `gfx`, `input`, `sys`, `fs`, and `audio`.

## License

[MIT](LICENSE).
