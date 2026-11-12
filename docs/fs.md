# fs

Pass path strings, such as `/sd/file.lua` or `/rec/sys/system.lua`. The recovery mount is read-only. On filesystem failure, each function returns `nil, message, errno`.

| API | Success result |
| --- | --- |
| `fs.list(path)` | An array of tables with `name` and, when supplied by the filesystem, `type` (`"dir"` or `"file"`), in directory iteration order, excluding `.` and `..`. |
| `fs.stat(path)` | A table with `type` (`"dir"` or `"file"`), `size` in bytes, and `mtime` in Unix seconds. |
| `fs.mkdir(path)` | `true` after creating one directory. |
| `fs.rename(from, to)` | `true` after renaming or moving a path. |
| `fs.remove(path)` | `true` after removing a file or empty directory. |

On the SD card, `fs.list` gets names and types together during directory iteration. Entries can change after enumeration.
