---@meta

---TabOS keyboard LEDs, system metrics, and clock.
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

---Return the battery percentage, or nil if unavailable.
---@return integer? percent
function sys.bat_lvl() end

---Return whether the battery is charging, or nil if its status is unknown.
---@return boolean? charging
function sys.bat_chrg() end

---Pause the Lua task for approximately the requested milliseconds (scheduler tick resolution).
---@param milliseconds integer Duration (0–60000); 0 returns immediately.
function sys.sleep(milliseconds) end

---Return the system clock as Unix seconds.
---@return integer timestamp
function sys.get_time() end

---Set the hardware RTC and system clock. Raises an error on failure.
---@param timestamp integer Unix seconds in UTC years 2000–2099 (946684800–4102444799).
function sys.set_time(timestamp) end
