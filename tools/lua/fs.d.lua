---@meta

---@class fs.Stat
---@field type "dir"|"file" Entry type.
---@field size integer Size in bytes.
---@field mtime integer Modification time in Unix seconds.

---@class fs.DirEntry
---@field name string Entry name.
---@field type? "dir"|"file" Entry type when reported by the filesystem.

---TabOS filesystem operations. Paths include /sd/file.lua and /rec/sys/system.lua.
---The recovery mount is read-only. Filesystem failures return nil, message, errno.
fs = {}

---List entry names and available types in directory iteration order, excluding `.` and `..`.
---@param path string Directory path.
---@return fs.DirEntry[]? entries Directory entries, or nil on failure.
---@return string? message Error message on failure.
---@return integer? errno Error number on failure.
function fs.list(path) end

---Read entry type, size, and modification time.
---@param path string File or directory path.
---@return fs.Stat? info Entry metadata, or nil on failure.
---@return string? message Error message on failure.
---@return integer? errno Error number on failure.
function fs.stat(path) end

---Read a data-only Lua table literal without executing code.
---@param path string Data file path.
---@return table? config Parsed configuration, or nil on failure.
---@return string? message Error message on failure.
---@return integer? errno Error number on filesystem failure.
function fs.read_table(path) end

---Write a Lua table literal. Cycles and unsupported types return an error.
---@param path string Data file path.
---@param data table Root table with string, finite number, or boolean keys.
---@return true? success True on success, or nil on failure.
---@return string? message Error message or backup cleanup warning.
---@return integer? errno Error number on filesystem failure.
function fs.write_table(path, data) end

---Create one directory; parent directories must already exist.
---@param path string Directory path.
---@return true? success True on success, or nil on failure.
---@return string? message Error message on failure.
---@return integer? errno Error number on failure.
function fs.mkdir(path) end

---Rename or move a path.
---@param from string Source path.
---@param to string Destination path.
---@return true? success True on success, or nil on failure.
---@return string? message Error message on failure.
---@return integer? errno Error number on failure.
function fs.rename(from, to) end

---Remove a file or empty directory.
---@param path string File or directory path.
---@return true? success True on success, or nil on failure.
---@return string? message Error message on failure.
---@return integer? errno Error number on failure.
function fs.remove(path) end
