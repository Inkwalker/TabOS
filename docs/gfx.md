# gfx

Drawing uses a 320 × 180 landscape canvas with origin `(0, 0)` at the top left. Coordinates are integers from −32768 to 32767. Colors are RGB565 integers from 0 to 65535. An optional drawing color defaults to the current color when omitted or `nil`. The initial drawing color is white.

| API | Behavior |
| --- | --- |
| `gfx.width`, `gfx.height` | Canvas dimensions in pixels. |
| `gfx.cls([color])` | Fill the canvas. Defaults to black. |
| `gfx.flip()` | Submit a copy of the canvas for asynchronous presentation. Replaces any pending frame and leaves the drawing pixels intact. Raises an error if submission fails. |
| `gfx.presenter_fps()` | Return the last sampled display presentation rate, or `0` before the first sample. |
| `gfx.color(color)` | Set the current drawing color. |
| `gfx.rgb(r, g, b)` | Pack three integer channels in 0–255 into an RGB565 integer. |
| `gfx.rgb(color)` | Unpack RGB565 into three 8-bit channel values `r, g, b`. |
| `gfx.pset(x, y [, color])` | Draw a pixel. |
| `gfx.pget(x, y)` | Read a pixel from the drawing canvas as RGB565. |
| `gfx.circ(x, y, radius [, color])` | Draw a circle outline centered at `(x, y)`. |
| `gfx.circfill(x, y, radius [, color])` | Draw a filled circle. |
| `gfx.oval(x, y, rx, ry [, color])` | Draw an ellipse outline centered at `(x, y)`. |
| `gfx.ovalfill(x, y, rx, ry [, color])` | Draw a filled ellipse. |
| `gfx.rect(x, y, width, height [, color])` | Draw a rectangle outline from the top-left corner. |
| `gfx.rectfill(x, y, width, height [, color])` | Draw a filled rectangle from the top-left corner. |
| `gfx.line(x1, y1, x2, y2 [, color])` | Draw a line including both endpoints. |
| `gfx.print(x, y, text [, color])` | Draw a string starting at `(x, y)` with automatic wrapping disabled. |

Circle radii are integers in 0–32767, ellipse radii in 0–512, and rectangle dimensions in 1–32767. Drawing and setter calls return no values.
