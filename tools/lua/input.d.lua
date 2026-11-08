---@meta

---@class input.Touch
---@field id integer Contact identifier.
---@field x integer Horizontal position in canvas pixels.
---@field y integer Vertical position in canvas pixels.

---TabOS touch, keyboard, and IMU input.
---Poll with input.update() before reading each frame; the recovery shell does this for managed apps.
input = {}

---Poll device input and buffer keyboard text.
function input.update() end

---Return active contacts, using the drawing canvas orientation and scale.
---@return input.Touch[] touches
function input.touch() end

---Return whether a key is held, or nil if the keyboard is unavailable.
---@param row integer Matrix row (1–5).
---@param col integer Matrix column (1–14).
---@return boolean? held
function input.key(row, col) end

---Return whether a key was pressed in the latest poll, or nil if unavailable.
---@param row integer Matrix row (1–5).
---@param col integer Matrix column (1–14).
---@return boolean? pressed
function input.keyp(row, col) end

---Return whether a key was released in the latest poll, or nil if unavailable.
---@param row integer Matrix row (1–5).
---@param col integer Matrix column (1–14).
---@return boolean? released
function input.keyr(row, col) end

---Return and clear buffered keyboard text; returns "" when empty.
---The buffer holds up to 256 bytes and skips Ctrl and Alt combinations.
---@return string text
function input.txt() end

---Return accelerometer readings in g, or nil if unavailable.
---@return number? x
---@return number? y
---@return number? z
function input.accel() end

---Return gyroscope readings in degrees per second, or nil if unavailable.
---@return number? x
---@return number? y
---@return number? z
function input.gyro() end
