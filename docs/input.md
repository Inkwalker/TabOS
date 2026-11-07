# input

Call `input.update()` before reading touch or keyboard state each frame. The recovery shell already polls input for apps it runs.

| API | Behavior |
| --- | --- |
| `input.update()` | Poll device input and buffer keyboard text. Returns no values. |
| `input.touch()` | Return an array of active contacts. Each entry has integer fields `id`, `x`, and `y`. Coordinates use the drawing canvas orientation and scale. |
| `input.key(row, col)` | Return whether a key is held. |
| `input.keyp(row, col)` | Return whether a key was pressed in the latest poll. |
| `input.keyr(row, col)` | Return whether a key was released in the latest poll. |
| `input.txt()` | Return and clear buffered keyboard text. Returns `""` when empty. The buffer holds up to 256 bytes and skips Ctrl and Alt combinations. |
| `input.accel()` | Return accelerometer readings `x, y, z` in g, or `nil` if unavailable. |
| `input.gyro()` | Return gyroscope readings `x, y, z` in degrees per second, or `nil` if unavailable. |

Keyboard queries take integer matrix rows 1–5 and columns 1–14. They return `nil` when the keyboard is unavailable.
