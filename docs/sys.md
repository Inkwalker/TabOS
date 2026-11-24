# sys

| API | Behavior |
| --- | --- |
| `sys.shutdown()` | Request device power-off through `M5.Power.powerOff()`. |
| `sys.sleep()` | Turn off the backlight, preserving the stored brightness setting. The panel and application stay active so touch can wake the screen. |
| `sys.wakeup()` | Wake the screen and restore its stored brightness. |
| `sys.set_brightness(brightness)` | Set screen backlight brightness as an integer from 0 to 255. Zero turns the backlight off. Invalid values raise an error. Returns no values. |
| `sys.get_brightness()` | Return the stored brightness setting as an integer from 0 to 255, including while the screen sleeps. |
| `sys.wait(milliseconds)` | Pause the Lua task, yielding CPU time, for approximately the requested duration (integer 0–60000 ms, scheduler tick resolution). Zero returns immediately. |
| `sys.set_led(led, r, g, b)` | Set keyboard LED 1 (left) or 2 (right) with integer RGB channels in 0–255. Returns a success boolean. |
| `sys.set_led_brightness(percent)` | Set keyboard LED brightness as an integer from 0 to 100. Returns a success boolean. |
| `sys.sram()` | Return `used, total` bytes of byte-addressable internal heap. |
| `sys.psram()` | Return `used, total` bytes of byte-addressable external heap. |
| `sys.cpu_load()` | Return one utilization percentage per core in core order, measured since the previous call. The first call returns `nil`. Sampling failure raises an error. |
| `sys.bat()` | Return a battery status table containing `percent`, `charging`, `current`, and `voltage`. |
| `sys.get_time()` | Return the system clock as integer Unix seconds. |
| `sys.set_time(timestamp)` | Set the hardware RTC and system clock from integer Unix seconds in UTC years 2000–2099. Returns no values and raises an error on failure. |

## Battery status

| Field | Value |
| --- | --- |
| `percent` | Charge level from `0.0` (empty) to `1.0` (full), or `nil` if unavailable. |
| `charging` | `true` while charging, `false` otherwise, or `nil` if unknown. |
| `current` | Signed integer milliamps. Positive means charging and negative means discharging. |
| `voltage` | Battery bus voltage in integer millivolts. |
