---@meta

---A PNG sprite backed by RGB565 pixels. Dimensions are read-only.
---Memory is released by close(), garbage collection, or a Lua <close> local.
---Reading dimensions or pixels, or drawing the sprite, after closing raises an error.
---@class gfx.Sprite
---@field width integer Width in pixels (1–32767).
---@field height integer Height in pixels (1–32767).
local Sprite = {}

---Read an RGB565 pixel relative to the sprite's top-left corner.
---@param x integer Coordinate from -32768 to 32767.
---@param y integer Coordinate from -32768 to 32767.
---@return integer color RGB565 color (0–65535).
function Sprite:pget(x, y) end

---Release sprite memory. Calling close more than once is safe.
function Sprite:close() end

---TabOS drawing API. The canvas origin is the top-left corner (0, 0).
---Coordinates are integers from -32768 to 32767; colors are RGB565 (0–65535).
---Optional drawing colors default to the current color (initially white).
gfx = {}

---@type integer
gfx.width = 320

---@type integer
gfx.height = 180

---Fill the drawing canvas. Defaults to black, independently of the current color.
---@param color? integer RGB565 color (0–65535).
function gfx.cls(color) end

---Submit a copy of the canvas for asynchronous presentation.
---Replaces any pending frame and leaves drawing pixels intact. Raises on failure.
---Resets the clip rectangle to the full canvas on success.
function gfx.flip() end

---Set the active canvas clip rectangle, replacing the previous rectangle.
---Restricts drawing (including cls) to its intersection with the canvas bounds.
---Resets to the full canvas after a successful flip.
---With no arguments, restore the active canvas bounds.
---@overload fun()
---@param x integer Coordinate from -32768 to 32767.
---@param y integer Coordinate from -32768 to 32767.
---@param w integer Width from 1 to 32767.
---@param h integer Height from 1 to 32767.
function gfx.clip(x, y, w, h) end

---Return the last sampled display presentation rate, or 0 before the first sample.
---@return number fps
function gfx.presenter_fps() end

---Set the current drawing color.
---@param color integer RGB565 color (0–65535).
function gfx.color(color) end

---Pack three integer channels (0–255) into RGB565.
---With one argument, unpack an RGB565 color into three 8-bit channels.
---@overload fun(color: integer): integer, integer, integer
---@param r integer Red channel (0–255).
---@param g integer Green channel (0–255).
---@param b integer Blue channel (0–255).
---@return integer color RGB565 color (0–65535).
function gfx.rgb(r, g, b) end

---Draw a pixel.
---@param x integer Coordinate from -32768 to 32767.
---@param y integer Coordinate from -32768 to 32767.
---@param color? integer RGB565 color; defaults to the current drawing color.
function gfx.pset(x, y, color) end

---Read a pixel from the drawing canvas.
---@param x integer Coordinate from -32768 to 32767.
---@param y integer Coordinate from -32768 to 32767.
---@return integer color RGB565 color (0–65535).
function gfx.pget(x, y) end

---Draw a circle outline centered at (x, y).
---@param x integer Coordinate from -32768 to 32767.
---@param y integer Coordinate from -32768 to 32767.
---@param radius integer Radius from 0 to 32767.
---@param color? integer RGB565 color; defaults to the current drawing color.
function gfx.circ(x, y, radius, color) end

---Draw a filled circle centered at (x, y).
---@param x integer Coordinate from -32768 to 32767.
---@param y integer Coordinate from -32768 to 32767.
---@param radius integer Radius from 0 to 32767.
---@param color? integer RGB565 color; defaults to the current drawing color.
function gfx.circfill(x, y, radius, color) end

---Draw an ellipse outline centered at (x, y).
---@param x integer Coordinate from -32768 to 32767.
---@param y integer Coordinate from -32768 to 32767.
---@param rx integer Horizontal radius from 0 to 512.
---@param ry integer Vertical radius from 0 to 512.
---@param color? integer RGB565 color; defaults to the current drawing color.
function gfx.oval(x, y, rx, ry, color) end

---Draw a filled ellipse centered at (x, y).
---@param x integer Coordinate from -32768 to 32767.
---@param y integer Coordinate from -32768 to 32767.
---@param rx integer Horizontal radius from 0 to 512.
---@param ry integer Vertical radius from 0 to 512.
---@param color? integer RGB565 color; defaults to the current drawing color.
function gfx.ovalfill(x, y, rx, ry, color) end

---Draw a rectangle outline from its top-left corner.
---@param x integer Coordinate from -32768 to 32767.
---@param y integer Coordinate from -32768 to 32767.
---@param width integer Width from 1 to 32767.
---@param height integer Height from 1 to 32767.
---@param color? integer RGB565 color; defaults to the current drawing color.
function gfx.rect(x, y, width, height, color) end

---Draw a filled rectangle from its top-left corner.
---@param x integer Coordinate from -32768 to 32767.
---@param y integer Coordinate from -32768 to 32767.
---@param width integer Width from 1 to 32767.
---@param height integer Height from 1 to 32767.
---@param color? integer RGB565 color; defaults to the current drawing color.
function gfx.rectfill(x, y, width, height, color) end

---Draw a line including both endpoints.
---@param x1 integer Coordinate from -32768 to 32767.
---@param y1 integer Coordinate from -32768 to 32767.
---@param x2 integer Coordinate from -32768 to 32767.
---@param y2 integer Coordinate from -32768 to 32767.
---@param color? integer RGB565 color; defaults to the current drawing color.
function gfx.line(x1, y1, x2, y2, color) end

---Draw text starting at (x, y), with automatic wrapping disabled.
---@param x integer Coordinate from -32768 to 32767.
---@param y integer Coordinate from -32768 to 32767.
---@param text string
---@param color? integer RGB565 color; defaults to the current drawing color.
function gfx.print(x, y, text, color) end

---Load a PNG at its native dimensions (each from 1 to 32767).
---PNG transparency is flattened against black; sprites do not retain alpha.
---Pixel storage requires approximately width * height * 2 bytes.
---@param path string PNG filesystem path.
---@return gfx.Sprite? sprite Loaded sprite, or nil on failure.
---@return string? error Error message on failure.
function gfx.load_sprite(path) end

---Draw a loaded sprite at (x, y).
---@param sprite gfx.Sprite
---@param x integer Coordinate from -32768 to 32767.
---@param y integer Coordinate from -32768 to 32767.
---@param transparent? integer RGB565 color key to skip; nil draws every pixel.
---@param flip_x? boolean Mirror horizontally during drawing; defaults to false.
---@param flip_y? boolean Mirror vertically during drawing; defaults to false.
function gfx.spr(sprite, x, y, transparent, flip_x, flip_y) end

---Draw a source rectangle using CPU nearest-neighbor scaling (no PPA).
---Respects the destination clip rectangle without changing sampling.
---Samples outside the sprite leave the destination unchanged; source stays unchanged.
---Use nil placeholders to skip optional arguments before later arguments.
---@param sprite gfx.Sprite
---@param sx integer Source left coordinate (-32768 to 32767).
---@param sy integer Source top coordinate (-32768 to 32767).
---@param sw integer Source width (1 to 32767).
---@param sh integer Source height (1 to 32767).
---@param dx integer Destination left coordinate (-32768 to 32767).
---@param dy integer Destination top coordinate (-32768 to 32767).
---@param dw? integer Destination width (1 to 32767); defaults to sw.
---@param dh? integer Destination height (1 to 32767); defaults to sh.
---@param key? integer RGB565 color key to skip; nil draws every pixel.
---@param flip_x? boolean Mirror the source rectangle horizontally; defaults to false.
---@param flip_y? boolean Mirror the source rectangle vertically; defaults to false.
function gfx.sspr(sprite, sx, sy, sw, sh, dx, dy, dw, dh, key, flip_x, flip_y) end
