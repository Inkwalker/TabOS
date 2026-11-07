local Document = require("document")
local Files = {}
Files.__index = Files
local Session = {}
Session.__index = Session

function Files.new(io_api, fs_api)
    return setmetatable({io = io_api, fs = fs_api}, Files)
end

function Files:read(path)
    local file, err = self.io.open(path, "rb")
    if not file then return nil, err end
    local bytes, read_error = file:read(Document.limit + 1)
    local closed, close_error = file:close()
    if not bytes and read_error then return nil, read_error end
    if not closed then return nil, close_error end
    bytes = bytes or ""
    if #bytes > Document.limit then return nil, "File exceeds 64 KiB" end
    return bytes
end

function Files:unused_name(path, suffix)
    local parent = path:match("^(.*)/[^/]+$")
    for n = 1, 999 do
        local candidate = parent .. "/ted" .. n .. "." .. suffix
        if candidate:lower() ~= path:lower() then
            local info, err, code = self.fs.stat(candidate)
            if not info then
                if code == 2 then return candidate end
                return nil, err
            end
        end
    end
    return nil, "No free recovery filename"
end

function Files:open(path)
    if path:sub(1, 4):lower() ~= "/sd/" then return nil, "Editor needs a writable /sd path" end
    local info, err, code = self.fs.stat(path)
    if not info and code ~= 2 then return nil, err end
    if info and info.type ~= "file" then return nil, "Path is a directory" end
    local parent = self.fs.stat(path:match("^(.*)/[^/]+$"))
    if not parent or parent.type ~= "directory" then return nil, "Parent directory unavailable" end
    local bytes = ""
    if info then
        bytes, err = self:read(path)
        if not bytes then return nil, err end
    end
    local document
    document, err = Document.new(bytes, not info)
    if not document then return nil, err end
    -- Non-truncating access check; new files are probed using a sibling temp file.
    local probe = path
    if not info then
        probe, err = self:unused_name(path, "tmp")
        if not probe then return nil, err end
    end
    local handle
    handle, err = self.io.open(probe, info and "r+b" or "wb")
    if not handle then return nil, err end
    local closed, close_error = handle:close()
    local removed, remove_error = true
    if not info then removed, remove_error = self.fs.remove(probe) end
    if not removed then return nil, "Probe retained: " .. probe .. ": " .. tostring(remove_error) end
    if not closed then return nil, close_error end
    return setmetatable({files = self, path = path, document = document}, Session)
end

function Session:check_current()
    local files = self.files
    local info, err, code = files.fs.stat(self.path)
    if not info then
        if code ~= 2 then return nil, err end
        if self.document.is_new then return true end
    elseif not self.document.is_new and info.type == "file" then
        local current
        current, err = files:read(self.path)
        if not current then return nil, err end
        if current == self.document.saved then return true end
    end
    return nil, "File changed externally; save refused"
end

function Session:save()
    self.document:end_group()
    local ok, err = self:check_current()
    if not ok then return nil, err end
    local files = self.files
    local temp
    temp, err = files:unused_name(self.path, "tmp")
    if not temp then return nil, err end
    local backup
    if not self.document.is_new then
        backup, err = files:unused_name(self.path, "bak")
        if not backup then return nil, err end
    end
    local handle
    handle, err = files.io.open(temp, "wb")
    if not handle then return nil, err end
    local written, write_error = handle:write(self.document:serialize())
    local closed, close_error = handle:close()
    if not written or not closed then
        return nil, tostring(write_error or close_error) .. "; temp retained: " .. temp
    end
    -- Check again after preparing the replacement, narrowing the MTP race window.
    ok, err = self:check_current()
    if not ok then return nil, err .. "; temp retained: " .. temp end
    if backup then
        ok, err = files.fs.rename(self.path, backup)
        if not ok then return nil, tostring(err) .. "; temp retained: " .. temp end
    end
    ok, err = files.fs.rename(temp, self.path)
    if not ok then
        if backup then
            local restored, restore_error = files.fs.rename(backup, self.path)
            if not restored then
                return nil, tostring(err) .. "; rollback: " .. tostring(restore_error)
                    .. "; recovery files: " .. temp .. " and " .. backup
            end
        end
        return nil, tostring(err) .. "; temp retained: " .. temp
    end
    self.document:mark_saved()
    if backup then
        local removed = files.fs.remove(backup)
        if not removed then return true, "Saved; backup retained: " .. backup end
    end
    return true, "Saved"
end

return Files
