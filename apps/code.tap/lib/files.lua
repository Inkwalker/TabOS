local Document = require("document")
local fat_upper = require("fat_case")
local Encoding = require("filename_encoding")
local Files = {}
local missing = 2 -- ENOENT

local function name_length(name)
    if name == "" or name:find('[%z\1-\31\127/\\:*?"<>|]') or name:match("^[ .]+$") then return nil end
    return Encoding.utf16_length(name)
end

function Files.resolve(path)
    if path == "" then return nil, "Invalid file path" end
    for part in path:gmatch("[^/]+") do
        if part ~= "." and part ~= ".." and not name_length(part) then return nil, "Invalid file path" end
    end
    if path:sub(1, 1) ~= "/" then path = "/sd/" .. path end
    path = os.path(path)
    if path:sub(1, 4):lower() ~= "/sd/" then return nil, "Choose a file under /sd" end
    return "/sd/" .. path:sub(5)
end

function Files.key(path)
    return fat_upper((path:gsub("[^/]+", function(part)
        return (part:gsub("[ .]+$", ""))
    end)))
end

function Files.parent(path)
    return path:match("^(.*)/[^/]+$")
end

function Files.recovery_directory()
    return os.path(".recovery")
end

-- The Lua filesystem exposes directory names but no inode or FAT short alias.
-- Require a listed name so a short alias cannot replace an open long-name file.
function Files.named_child(folder, name)
    local names, err = fs.list(folder)
    if not names then return nil, "List failed: " .. (err or folder) end
    local key = Files.key(name)
    for _, entry in ipairs(names) do
        if name_length(entry) and Files.key(entry) == key then return folder .. "/" .. entry end
    end
    return nil, "Name not found. Use the name shown in the SD browser: " .. name
end

function Files.startup_path(path)
    local resolved, err = Files.resolve(path)
    if not resolved then return nil, err end
    local current = "/sd"
    for part in resolved:sub(5):gmatch("[^/]+") do
        current, err = Files.named_child(current, part)
        if not current then return nil, err end
    end
    return current
end

function Files.target(folder, name)
    local length = name_length(name)
    if not length or name:match("[ .]$") then return nil, "Enter a valid filename" end
    if length > 255 then return nil, "Filename exceeds 255 characters" end
    return folder .. "/" .. name
end

function Files.list(folder)
    local names, err = fs.list(folder)
    if not names then return nil, err or folder end
    local entries = {}
    local recovery_key = Files.key(Files.recovery_directory())
    for _, name in ipairs(names) do
        local path = folder .. "/" .. name
        if name_length(name) and Files.key(path) ~= recovery_key then
            local info, stat_error, code = fs.stat(path)
            if info then
                entries[#entries + 1] = {name = name, path = path, key = fat_upper(name),
                    directory = info.type == "directory"}
            elseif code ~= missing then
                return nil, stat_error or path
            end
        end
    end
    table.sort(entries, function(a, b)
        if a.directory ~= b.directory then return a.directory end
        if a.key ~= b.key then return a.key < b.key end
        return a.name < b.name
    end)
    return entries
end

-- Return exact bytes, nil for an absent path, or an error. Incompatible
-- targets count as changes when comparing against a previous snapshot.
function Files.snapshot(path)
    local info, err, code = fs.stat(path)
    if not info then
        if code == missing then return nil end
        return nil, "Stat failed: " .. (err or path)
    end
    if info.type ~= "file" then return nil, "Path is a directory", true end
    if info.size > Document.limit then return nil, "File exceeds 64 KiB", true end
    local file
    file, err, code = io.open(path, "rb")
    if not file then
        if code == missing then return nil end
        return nil, "Open failed: " .. (err or path)
    end
    local bytes, read_error = file:read(Document.limit + 1)
    local closed, close_error = file:close()
    if read_error then return nil, "Read failed: " .. read_error end
    if not closed then return nil, "Close after read failed: " .. (close_error or path) end
    bytes = bytes or ""
    if #bytes > Document.limit then return nil, "File exceeds 64 KiB", true end
    return bytes
end

function Files.read(path, history)
    local bytes, err = Files.snapshot(path)
    if not bytes then return nil, err or "File unavailable" end
    return Document.new(bytes, history)
end

local function unused_sibling(path, extension)
    local parent, key = Files.parent(path), Files.key(path)
    for _ = 1, 32 do
        local name = string.format("%s/c%07x.%s", parent, math.random(0, 0xfffffff), extension)
        if Files.key(name) ~= key then
            local info, err, code = fs.stat(name)
            if not info then
                if code == missing then return name end
                return nil, "Recovery name check failed: " .. (err or name)
            end
        end
    end
    return nil, "No free recovery filename"
end

local function check_target(path, expected)
    local actual, err, incompatible = Files.snapshot(path)
    if incompatible or (not err and actual ~= expected) then
        return nil, "Target changed externally: " .. path, true
    end
    if err then return nil, err end
    return true
end

function Files.save(path, expected, bytes)
    local ok, err, changed = check_target(path, expected)
    if not ok then return nil, err, changed end
    local temp, backup
    temp, err = unused_sibling(path, "tmp")
    if not temp then return nil, err end
    if expected then
        backup, err = unused_sibling(path, "bak")
        if not backup then return nil, err end
    end

    local handle
    handle, err = io.open(temp, "wb")
    if not handle then return nil, "Open temporary file failed: " .. (err or temp) end
    local written, write_error = handle:write(bytes)
    local closed, close_error = handle:close()
    if not written or not closed then
        local detail = not written and ("Write failed: " .. (write_error or temp)) or ""
        if not closed then
            detail = detail .. (written and "" or "\n") .. "Close after write failed: " .. (close_error or temp)
        end
        return nil, detail .. "\nTemporary file: " .. temp
    end

    ok, err, changed = check_target(path, expected)
    if not ok then
        local removed, remove_error = fs.remove(temp)
        if not removed then
            err = err .. "\nTemporary file cleanup failed: " .. (remove_error or "unknown error")
                .. "\nTemporary file: " .. temp
        end
        return nil, err, changed
    end
    if backup then
        ok, err = fs.rename(path, backup)
        if not ok then
            return nil, "Backup rename failed: " .. (err or "unknown error") .. "\nTemporary file: " .. temp
                .. "\nCheck original: " .. path .. "\nCheck backup: " .. backup
        end
    end
    ok, err = fs.rename(temp, path)
    if not ok then
        local detail = "Replacement rename failed: " .. (err or "unknown error") .. "\nTarget: " .. path
            .. "\nTemporary file: " .. temp
        if backup then
            local restored, restore_error = fs.rename(backup, path)
            if not restored then
                return nil, detail .. "\nRollback failed: " .. (restore_error or "unknown error")
                    .. "\nBackup file: " .. backup
            end
            detail = detail .. "\nOriginal restored."
        end
        return nil, detail
    end
    if backup then
        local removed, remove_error = fs.remove(backup)
        if not removed then
            return true, "Backup cleanup failed: " .. (remove_error or "unknown error") .. "\nBackup file: " .. backup
        end
    end
    return true
end

return Files
