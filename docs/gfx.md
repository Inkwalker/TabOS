# gfx

Drawing starts with a 320 × 180 landscape canvas with origin `(0, 0)` at the top left. Coordinates are integers from −32768 to 32767. Colors are RGB565 integers from 0 to 65535. An optional drawing color defaults to the current color when omitted or `nil`. The initial drawing color is white.

| API | Behavior |
| --- | --- |
| `gfx.width`, `gfx.height` | Active canvas dimensions in pixels. |
| `gfx.target(width, height)` | Wait for preceding commands, discard the previous canvas, and select a fresh black canvas. Reset clipping and the text cursor. Dimensions must be in 1–32767 and `width * height` must be at most 65536. |
| `gfx.target()` | Select a fresh black 320 × 180 canvas, discarding the previous canvas. |
| `gfx.cls([color])` | Fill the canvas. Defaults to black. |
| `gfx.flip()` | Wait for queued drawing, then copy the active canvas into the retained 320 × 180 screen image at its top-left corner. Clip excess pixels and preserve the screen outside the canvas. Submit the screen image for asynchronous display, replacing any pending frame. Leave canvas pixels intact and reset clipping on success. Raise an error on failure. |
| `gfx.flip(sprite)` | Wait for queued drawing, then save all canvas pixels to an equally sized sprite. Leave canvas pixels intact and reset clipping. Raise an error for a closed or differently sized sprite. |
| `gfx.clip(x, y, w, h)` | Replace the active canvas clip rectangle. Restrict drawing, including `cls`, to its intersection with canvas bounds. Dimensions must be in 1–32767. |
| `gfx.clip()` | Reset the clip rectangle to the active canvas size. |
| `gfx.presenter_fps()` | Return the last sampled display presentation rate, or `0` before the first sample. |
| `gfx.color(color)` | Set the current drawing color. |
| `gfx.rgb(r, g, b)` | Pack three integer channels in 0–255 into an RGB565 integer. |
| `gfx.rgb(color)` | Unpack RGB565 into three 8-bit channel values `r, g, b`. |
| `gfx.pset(x, y [, color])` | Draw a pixel. |
| `gfx.pget(x, y)` | Wait for queued drawing to finish, then read a pixel from the drawing canvas as RGB565. |
| `gfx.circ(x, y, radius [, color])` | Draw a circle outline centered at `(x, y)`. |
| `gfx.circfill(x, y, radius [, color])` | Draw a filled circle. |
| `gfx.oval(x, y, rx, ry [, color])` | Draw an ellipse outline centered at `(x, y)`. |
| `gfx.ovalfill(x, y, rx, ry [, color])` | Draw a filled ellipse. |
| `gfx.rect(x, y, width, height [, color])` | Draw a rectangle outline from the top-left corner. |
| `gfx.rectfill(x, y, width, height [, color])` | Draw a filled rectangle from the top-left corner. |
| `gfx.line(x1, y1, x2, y2 [, color])` | Draw a line including both endpoints. |
| `gfx.tline(spr, x0, y0, x1, y1, sx, sy, sdx, sdy)` | Draw a textured line including both endpoints, starting with sprite position `(sx, sy)` and advancing it by `(sdx, sdy)` per line pixel. |
| `gfx.print(x, y, text [, color])` | Draw a string starting at `(x, y)` with automatic wrapping disabled. |
| `gfx.load_sprite(path)` | Load a PNG at its native dimensions. Return a sprite object, or `nil, error` on failure. |
| `gfx.create_sprite(width, height)` | Allocate a black RGB565 sprite in PSRAM. Dimensions must be in 1–32767. Return a sprite object, or `nil, error` on allocation failure. |
| `gfx.spr(sprite, x, y [, transparent [, flip_x [, flip_y]]])` | Draw a sprite with its top-left at `(x, y)`. Optional `transparent` skips an RGB565 color. Mirror flags default to `false`. |
| `sprite.width`, `sprite.height` | Read-only sprite dimensions in pixels. |
| `gfx.sspr(sprite, sx, sy, sw, sh, dx, dy [, dw [, dh [, key [, flip_x [, flip_y]]]]])` | Draw a source rectangle at `(dx, dy)` with nearest-neighbor scaling. `dw` and `dh` default to `sw` and `sh`. Color key and mirror flags work as in `spr`. |
| `sprite:pget(x, y)` | Read a sprite pixel as RGB565, relative to its top-left corner `(0, 0)`. |
| `sprite:save(path)` | Write the whole sprite as an opaque PNG, overwriting an existing file. Return `true`, or `nil, error` on encoding or file failure. Parent directories must already exist. |
| `sprite:close()` | Release sprite memory. Closing more than once is safe. |

Circle radii are integers in 0–32767, ellipse radii in 0–512, and rectangle dimensions in 1–32767. Drawing and setter calls return no values.

Sprite and `sspr` dimensions must be in 1–32767. PNG transparency is flattened against black; sprites do not retain alpha.

Sprite drawing respects canvas bounds and the active clip rectangle without changing the source. In `sspr`, samples outside the sprite leave destination pixels unchanged. Use `nil` to skip optional arguments before later ones.

In `tline`, source positions and steps are required finite numbers and may be fractional. Source positions wrap independently at the sprite width and height, including negative positions and steps; each sample uses `floor` of the wrapped position. Sampling starts at `(x0, y0)` and advances toward `(x1, y1)`, even across clipped pixels. A zero-length line draws one sample. All sampled colors are drawn.

Sprites are released by garbage collection, VM shutdown, `sprite:close()`, or a Lua `<close>` local. Using a closed sprite raises an error, except for repeated `close()` calls.

All temporary canvases reuse one dedicated 128 KiB SRAM pixel buffer. Selecting a target always clears its pixels, even when its dimensions match the previous target. Drawing color remains global. Sprites and the retained screen image live in PSRAM. Display presentation uses the existing 4× scaling. Saving to a sprite leaves the retained screen image unchanged.

Drawing and clip changes are copied into a bounded FIFO command buffer and executed on core 0. Calls return after enqueueing; a full buffer waits for space. `gfx.target()`, `gfx.pget()` and both forms of `gfx.flip()` block until all preceding commands and their own operation have completed. Display scanout remains asynchronous. Colors are captured when a draw is enqueued. Text is copied into the buffer. Sprite loading stays on core 1; closing or collecting a sprite waits for queued drawing before releasing its pixels.
