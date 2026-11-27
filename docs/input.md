# input

Call `input.update()` before reading input each frame. The shell already polls input for apps it runs.

| API | Behavior |
| --- | --- |
| `input.update()` | Poll device input, buffer keyboard text, and snapshot mouse input. Returns no values. |
| `input.touch()` | Return an array of active contacts. Each entry has integer fields `id`, `x`, and `y`. Coordinates use the drawing canvas orientation and scale. |
| `input.mouse()` | Return the USB-A mouse state from the latest poll. |
| `input.key(row, col)` | Return whether a key is held. |
| `input.keyp(row, col)` | Return whether a key was pressed in the latest poll. |
| `input.keyr(row, col)` | Return whether a key was released in the latest poll. |
| `input.txt()` | Return and clear buffered keyboard text. Returns `""` when empty. The buffer holds up to 256 bytes and skips Ctrl and Alt combinations. |
| `input.accel()` | Return accelerometer readings `x, y, z` in g, or `nil` if unavailable. |
| `input.gyro()` | Return gyroscope readings `x, y, z` in degrees per second, or `nil` if unavailable. |

Keyboard queries take integer matrix rows 1–5 and columns 1–14. They return `nil` when the keyboard is unavailable.

## USB-A mouse

`input.mouse()` returns a table even when no mouse is connected:

| Field | Meaning |
| --- | --- |
| `connected` | Whether a supported mouse interface is active. |
| `dx`, `dy` | Relative movement in device counts since the previous poll. Positive values move right and down. |
| `wheel` | Vertical wheel delta in device counts since the previous poll. |
| `buttons` | Bit mask of currently held buttons. |
| `pressed`, `released` | Bit masks of button transitions since the previous poll. A quick click can set the same bit in both. |

Button bits follow HID usage order. Left is `1`, right is `2`, middle is `4`, and additional buttons use the subsequent bits. Test a button with an expression such as `(input.mouse().pressed & 1) ~= 0`.

Input accumulates between polls. Repeated reads in the same frame return the same values. Unplugging releases held buttons in the next poll. Report Protocol supplies the wheel and additional buttons when the descriptor exposes them. Boot Protocol supplies relative movement and three buttons.

TabOS reads one mouse interface on the built-in USB-A port. Apps can use these reports to implement a pointer or their own controls.
