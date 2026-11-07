# sys

| API | Behavior |
| --- | --- |
| `sys.set_led(led, r, g, b)` | Set keyboard LED 1 (left) or 2 (right) with integer RGB channels in 0–255. Returns a success boolean. |
| `sys.set_led_brightness(percent)` | Set keyboard LED brightness as an integer from 0 to 100. Returns a success boolean. |
| `sys.sram()` | Return `used, total` bytes of byte-addressable internal heap. |
| `sys.psram()` | Return `used, total` bytes of byte-addressable external heap. |
| `sys.cpu_load()` | Return one utilization percentage per core in core order, measured since the previous call. The first call returns `nil`. Sampling failure raises an error. |
| `sys.bat_lvl()` | Return the battery percentage as an integer, or `nil` if unavailable. |
| `sys.bat_chrg()` | Return whether the battery is charging, or `nil` if the status is unknown. |
| `sys.get_time()` | Return the system clock as integer Unix seconds. |
| `sys.set_time(timestamp)` | Set the hardware RTC and system clock from integer Unix seconds in UTC years 2000–2099. Returns no values and raises an error on failure. |
