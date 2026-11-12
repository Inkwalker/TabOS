# fs

Use path strings such as `/sd/file.lua` or `/rec/sys/system.lua`. `/rec` is read-only. Filesystem failures return `nil, message, errno`.

## Files and directories

| API | Success result |
| --- | --- |
| `fs.list(path)` | Array of entries with `name` and optional `type` (`"dir"` or `"file"`), in directory order; excludes `.` and `..`. |
| `fs.stat(path)` | Table with `type` (`"dir"` or `"file"`), `size` in bytes, and `mtime` in Unix seconds. |
| `fs.mkdir(path)` | `true` after creating one directory. |
| `fs.rename(from, to)` | `true` after renaming or moving a path. |
| `fs.remove(path)` | `true` after removing a file or empty directory. |

On SD, `fs.list` reads names and types together. Entries may change after listing.

## Table files

| API | Success result |
| --- | --- |
| `fs.read_table(path)` | Lua table parsed from a data-only table literal; never compiles or executes the file. |
| `fs.write_table(path, data)` | `true` after writing a table literal. May return `true, message` if backup cleanup fails. |

Use `.ltab` by convention; any path is accepted. Files must contain a root `{ ... }` without `return`. Both operations limit nesting to eight levels to fit the Lua task stack.

Syntax and serialization errors return `nil, message`; read errors include the path, line, and column. Filesystem errors also include `errno`.

```lua
local config = assert(fs.read_table("/sd/config.ltab"))
config.screen = { brightness = 80, accents = { "blue", "green" } }
assert(fs.write_table("/sd/config.ltab", config))
```

### Format

```lua
{
    -- Display settings
    screen = { brightness = 80, accents = { "blue", "green" } },
    ["key with spaces"] = "value",
}
```

| Supported | Details |
| --- | --- |
| Values | Finite decimal numbers (including fractions and exponents), booleans, quoted strings, and nested tables. |
| Fields | `name = value`, scalar keys such as `[3]` or `[false]`, and list entries. Mixed and sparse tables are allowed. |
| Separators | Commas or semicolons, including trailing separators. |
| Comments | `--` line comments. |

Single- and double-quoted strings support Lua short-string escapes: `\a`, `\b`, `\f`, `\n`, `\r`, `\t`, `\v`, `\\`, `\"`, `\'`, decimal byte escapes, `\xHH`, `\u{...}`, escaped newlines, and `\z` whitespace skipping. Strings and string keys may contain arbitrary bytes, including NUL.

Expressions, calls, variables, `nil`, hexadecimal numbers, long-bracket strings, and block comments are unsupported. Duplicate keys, including explicit-key/list-index collisions, are rejected.

Numbers use signed 32-bit integers and 32-bit floats. Out-of-range integers may become floats and lose precision.

### Writing and replacement

The writer reads raw entries without invoking metatables:

- Keys: strings, finite numbers, or booleans.
- Values: strings, finite numbers, booleans, or tables.
- Cycles and unsupported values return `nil, message`.
- Shared tables become independent copies; comments and field order are lost.

The writer serializes before opening the destination, writes a sibling temporary file, then replaces the destination. Validation failures preserve the existing file. If FAT replacement and rollback both fail, the error identifies the sibling backup. Successful writes with failed backup cleanup return `true, message`.
