---@meta

---TabOS power, display, keyboard LEDs, system metrics, and clock.
sys = {}

---Set a keyboard LED. Returns whether the hardware update succeeded.
---@param led integer LED 1 (left) or 2 (right).
---@param r integer Red channel (0–255).
---@param g integer Green channel (0–255).
---@param b integer Blue channel (0–255).
---@return boolean success
function sys.set_led(led, r, g, b) end

---Set keyboard LED brightness. Returns whether the hardware update succeeded.
---@param percent integer Brightness (0–100).
---@return boolean success
function sys.set_led_brightness(percent) end

---Return byte-addressable internal heap usage.
---@return integer used Used bytes.
---@return integer total Total bytes.
function sys.sram() end

---Return byte-addressable external heap usage.
---@return integer used Used bytes.
---@return integer total Total bytes.
function sys.psram() end

---Return utilization percentages since the previous call, in core order.
---The first call returns nil. Sampling failure raises an error.
---@return number? core0 Core 0 utilization (0–100).
---@return number? core1 Core 1 utilization (0–100); absent on single-core builds.
function sys.cpu_load() end

---@class BatteryStatus
---@field percent number? Charge level (0.0–1.0), or nil if unavailable.
---@field charging boolean? Whether the battery is charging, or nil if unknown.
---@field current integer Signed milliamps (positive charging, negative discharging).
---@field voltage integer Battery bus voltage in millivolts.

---Return the current battery status.
---@return BatteryStatus status
function sys.bat() end

---Request device power-off.
function sys.shutdown() end

---Turn off the backlight, preserving stored brightness and keeping touch active.
function sys.sleep() end

---Pause the Lua task for approximately the requested milliseconds (scheduler tick resolution).
---@param milliseconds integer Duration (0–60000); 0 returns immediately.
function sys.wait(milliseconds) end

---Wake the screen and restore its stored brightness.
function sys.wakeup() end

---Set screen backlight brightness. Invalid values raise an error.
---@param brightness integer Brightness (0–255); 0 turns the backlight off.
function sys.set_brightness(brightness) end

---Return the stored screen brightness setting, including while the screen sleeps.
---@return integer brightness Brightness (0–255).
function sys.get_brightness() end

---Return the system clock as Unix seconds.
---@return integer timestamp
function sys.get_time() end

---Set the hardware RTC and system clock. Raises an error on failure.
---@param timestamp integer Unix seconds in UTC years 2000–2099 (946684800–4102444799).
function sys.set_time(timestamp) end
