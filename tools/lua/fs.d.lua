---@meta

---@class fs.Stat
---@field type "directory"|"file" Entry type.
---@field size integer Size in bytes.
---@field mtime integer Modification time in Unix seconds.

---TabOS filesystem operations. Paths include /sd/file.lua and /rec/system.lua.
---The recovery mount is read-only. Filesystem failures return nil, message, errno.
fs = {}

---List entry names in directory iteration order, excluding `.` and `..`.
---@param path string Directory path.
---@return string[]? entries Entry names, or nil on failure.
---@return string? message Error message on failure.
---@return integer? errno Error number on failure.
function fs.list(path) end

---Read entry type, size, and modification time.
---@param path string File or directory path.
---@return fs.Stat? info Entry metadata, or nil on failure.
---@return string? message Error message on failure.
---@return integer? errno Error number on failure.
function fs.stat(path) end

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
