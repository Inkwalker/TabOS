# TabOS

Lua-based firmware for the **M5Stack Tab5 (ESP32-P4)**, built with ESP-IDF. Includes a shell, a 320×180 drawing canvas, touch/keyboard/IMU input, SD card storage, and USB MTP file transfer.

## Apps

The build packages `recovery_files/` into the recovery flash partition.
At boot, press **Del** within three seconds to enter recovery shell on the recovery partition. 

TabOS loads `/sd/sys/system.lua`, falling back to `/rec/sys/system.lua` if missing or unloadable.
Exact boot sequence is defined in `/recovery_files/boot.lua`.

This repo includes system scripts and app bundles in `sd_files/`. After flashing, copy the contents of `sd_files/sys/` to `/sd/sys/` and the `sd_files/*.tap` bundle directories to `/sd/apps/`. On an existing installation, keep your `/sd/sys/apps.ltab` preferences and add `files_app = "/sd/apps/files.tap"` to your system config if needed.

## Build and flash

Use an ESP-IDF **5.5.6** environment (the version recorded in `dependencies.lock`) and a Tab5. The Tab5 keyboard is used for the shell.

From an ESP-IDF terminal in this directory:

```sh
idf.py set-target esp32p4
idf.py build
idf.py -p PORT flash
```

Replace `PORT` with your device's serial port. Dependencies are resolved by the ESP-IDF Component Manager.

After dependencies are downloaded or refreshed, run `python tools/patch_esp_tinyusb_mtp.py`
and rebuild before flashing. This fixes an `esp_tinyusb` 3.0.0 MTP bug that shows
nested SD card files in the root directory. The script is safe to rerun.

Project is configured to run in VS Code.

## Firmware crash reports

TabOS reserves 256 KiB of internal flash for one firmware panic. The next time the
SD card mounts at boot, TabOS saves `panic.txt` and `coredump.bin` under
`/sd/crash/panic-NNNNNN/`. A missing card or failed export leaves the dump in
flash for another boot. Until export succeeds, the flash slot keeps the first
panic.

Use `idf.py coredump-info -c path/to/coredump.bin` with the build that produced
the crash to decode registers and call stacks. When upgrading, use a full
`idf.py -p PORT flash` to install the updated partition table. If an existing
local `sdkconfig` disables core dumps, select **Flash** under **Component config →
Core dump → Data destination** in `idf.py menuconfig` before building.

## Repository

For Lua completion and hover documentation in VS Code, install the recommended
**Lua** extension (`sumneko.lua`) and open this repository folder. Workspace
settings load the editor-only definitions in `tools/lua/` for `gfx`, `input`, `sys`,
`fs`, and `audio`, including sprite methods, waveform choices, and return types.

- `main/` — firmware and Lua bindings.
- `components/` — local keyboard component.
- `recovery_files/` — system scripts and widgets in `sys/`, system commands in `sys/bin/`, and the editor app.
- `sd_files/` — example scripts and apps.
- `docs/` — [Lua API reference](docs/README.md) for `gfx`, `input`, `sys`, `fs`, and `audio`.

## License

[MIT](LICENSE).
