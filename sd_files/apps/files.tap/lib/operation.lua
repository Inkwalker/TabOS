local Paths = require("paths")
local Operation = {}
Operation.__index = Operation

local missing, exists = 2, 17 -- errno values on the firmware
local cancelled = {}
local sequence = 0

local function check(ok, detail)
    if not ok then error(detail or "Filesystem operation failed", 0) end
    return ok
end

local function probe(path)
    local info, err, code = fs.stat(path)
    if not info and code ~= missing then check(nil, err) end
    return info or false
end

local function scratch(destination, extension)
    sequence = (sequence + 1) % 0xfffffff
    return Paths.join(Paths.parent(destination),
        string.format(".tabos-copy-%07x.%s", sequence, extension))
end

local function move_aside(path)
    for _ = 1, 64 do
        local backup = scratch(path, "bak")
        if not probe(backup) then
            local ok, err, code = fs.rename(path, backup)
            if ok then return backup end
            if code ~= exists then check(nil, err) end
        end
    end
    check(nil, "No free backup name beside " .. path)
end

local function restore(backup, destination, detail)
    local ok, err = fs.rename(backup, destination)
    if not ok then return detail .. "\nRollback failed: " .. err .. "\nBackup: " .. backup, backup end
    return detail
end

function Operation.rename(path, destination)
    if Paths.protected(path) then return nil, "Cannot rename a storage root" end
    if path == destination then return true end
    return pcall(function()
        if Paths.key(path) == Paths.key(destination) then
            local backup = move_aside(path)
            local ok, err = fs.rename(backup, destination)
            check(ok, not ok and restore(backup, path, err))
        else
            if probe(destination) then check(nil, "Name already exists: " .. destination) end
            check(fs.rename(path, destination))
        end
    end)
end

local conflicts = {
    file = {"Replace", "Skip", "Keep Both", "Cancel"},
    dir = {"Merge", "Skip", "Keep Both", "Cancel"},
    mixed = {"Skip", "Keep Both", "Cancel"},
    self = {"Keep Both", "Cancel"},
}

function Operation:ask(event)
    local answer, remaining = coroutine.yield(event)
    if answer == "Cancel" then
        if event.kind == "error" then self.current.failed = true end
        error(cancelled, 0)
    end
    return answer, remaining
end

function Operation:step(path, copied)
    self.path = path
    self:ask({kind = "progress", copied = copied})
end

function Operation:cleanup()
    if self.reader then self.reader:close() end
    if self.writer then self.writer:close() end
    self.reader, self.writer = nil, nil
    local temp = self.temp
    self.temp = nil
    if temp then
        local ok, err, code = fs.remove(temp)
        if not ok and code ~= missing then
            return "Temporary file cleanup failed: " .. (err or temp)
        end
    end
end

function Operation:attempt(path, work, ...)
    while true do
        self:step(path)
        local ok, result, message = pcall(work, ...)
        if ok and result ~= nil then return true, result end
        if ok then result = message or "Filesystem operation failed" end
        local leftover = self:cleanup()
        if leftover then self.details[#self.details + 1] = leftover end
        if result == cancelled then error(cancelled, 0) end
        local detail = path .. "\n" .. tostring(result)
        local answer = self:ask({kind = "error", detail = detail, options = {"Retry", "Skip", "Cancel"}})
        if answer ~= "Retry" then
            self.current.failed = true
            self.details[#self.details + 1] = detail
            return false
        end
    end
end

function Operation:conflict(kind, destination)
    local options = conflicts[kind]
    for _, option in ipairs(options) do
        if option == self.remaining then return option end
    end
    local detail = kind == "self" and "This is the source path." or "Destination already exists."
    local answer, remaining = self:ask({
        kind = "conflict", options = options, detail = detail .. "\n" .. destination,
        batch = kind ~= "self",
    })
    if remaining then self.remaining = answer end
    return answer
end

function Operation:other_name(path, is_file)
    local name = Paths.name(path)
    local stem, extension
    if is_file then stem, extension = name:match("^(.+)(%.[^.]+)$") end
    stem, extension = stem or name, extension or ""
    for number = 2, math.maxinteger do
        local suffix = " (" .. number .. ")"
        if #suffix + #extension < 255 then suffix = suffix .. extension end
        local prefix = stem:sub(1, 255 - #suffix)
        -- Avoid cutting a UTF-8 sequence at the filename limit.
        if #prefix < #stem and stem:byte(#prefix + 1) >= 128 and stem:byte(#prefix + 1) <= 191 then
            prefix = prefix:gsub("[\194-\244][\128-\191]*$", "")
        end
        local candidate = Paths.join(Paths.parent(path), prefix .. suffix)
        local ok, info = self:attempt(candidate, probe, candidate)
        if not ok then return nil end
        if not info then return candidate end
    end
end

function Operation:copy_file(source, destination, replacement)
    self.reader = check(io.open(source, "rb"))
    for _ = 1, 64 do
        local temporary = scratch(destination, "tmp")
        if Paths.key(temporary) ~= Paths.key(destination) then
            local writer, err, code = fs.open_new(temporary)
            if writer then
                self.writer, self.temp = writer, temporary
                break
            end
            if code ~= exists then check(nil, err) end
        end
    end
    check(self.writer, "No free temporary name beside " .. destination)
    local copied = 0.0
    while true do
        self:step(source, copied)
        local data, err = self.reader:read(8192)
        if not data then
            if err then check(nil, err) end
            break
        end
        check(self.writer:write(data))
        copied = copied + #data
    end
    local writer, reader = self.writer, self.reader
    self.writer, self.reader = nil, nil
    local written, write_error = writer:close()
    local read, read_error = reader:close()
    check(written, write_error)
    check(read, read_error)

    local present = probe(destination)
    local backup
    if replacement then
        if not present or present.type ~= "file" or present.size ~= replacement.size
            or present.mtime ~= replacement.mtime then
            check(nil, "Destination changed during copy: " .. destination)
        end
        backup = move_aside(destination)
    elseif present then
        check(nil, "Destination appeared during copy: " .. destination)
    end
    local ok, err = fs.rename(self.temp, destination)
    if not ok and backup then
        local retained
        err, retained = restore(backup, destination, err)
        if retained then self.details[#self.details + 1] = "Recoverable backup: " .. retained end
    end
    check(ok, err)
    self.temp = nil
    return backup or false
end

local function relocate(source, destination)
    if probe(destination) then check(nil, "Destination already exists: " .. destination) end
    return check(fs.rename(source, destination))
end

local function remove_copied_source(source, expected)
    local actual = check(fs.stat(source))
    if actual.type ~= "file" or actual.size ~= expected.size or actual.mtime ~= expected.mtime then
        check(nil, "Source changed during copy: " .. source)
    end
    return fs.remove(source)
end

function Operation:paste(source, destination)
    local moving = self.mode == "cut"
    local source_key, destination_key = Paths.key(source), Paths.key(destination)
    if moving and Paths.protected(source) then
        return self:attempt(source, function() error("Cannot move a storage root", 0) end)
    end
    if moving and source_key == destination_key then return true end
    local ok, info = self:attempt(source, fs.stat, source)
    if not ok then return false end
    if info.type == "dir" and destination_key:sub(1, #source_key + 1) == source_key .. "/" then
        return self:attempt(source, function() error("Cannot paste a folder inside itself", 0) end)
    end

    local present
    if source_key == destination_key then
        self:conflict("self", destination)
        destination = self:other_name(destination, info.type == "file")
        if not destination then return false end
    else
        ok, present = self:attempt(destination, probe, destination)
        if not ok then return false end
        if present then
            local kind = info.type == present.type and info.type or "mixed"
            local answer = self:conflict(kind, destination)
            if answer == "Skip" then
                self.current.skipped = true
                return false
            elseif answer == "Keep Both" then
                destination = self:other_name(destination, info.type == "file")
                if not destination then return false end
                present = nil
            end
        end
    end

    if moving and not present and Paths.volume(source) == Paths.volume(destination) then
        ok = self:attempt(source, relocate, source, destination)
        if ok then self.current.changed = true end
        return ok
    end
    if info.type == "file" then
        local backup
        ok, backup = self:attempt(source, self.copy_file, self, source, destination, present)
        if not ok then return false end
        self.current.changed = true
        if backup then
            self.backup = backup
            self:attempt(backup, fs.remove, backup)
            self.backup = nil
        end
        if moving then return self:attempt(source, remove_copied_source, source, info) end
        return true
    end

    local entries
    ok, entries = self:attempt(source, fs.list, source)
    if not ok then return false end
    if not present then
        ok = self:attempt(destination, fs.mkdir, destination)
        if not ok then return false end
        self.current.changed = true
    end
    local complete = true
    for _, entry in ipairs(entries) do
        if not self:paste(Paths.join(source, entry.name), Paths.join(destination, entry.name)) then
            complete = false
        end
    end
    if complete and moving then return self:attempt(source, fs.remove, source) end
    return complete
end

function Operation:delete(path)
    if Paths.protected(path) then
        return self:attempt(path, function() error("Cannot delete a storage root", 0) end)
    end
    local ok, info = self:attempt(path, fs.stat, path)
    if not ok then return false end
    if info.type == "dir" then
        local entries
        ok, entries = self:attempt(path, fs.list, path)
        if not ok then return false end
        local complete = true
        for _, entry in ipairs(entries) do
            if not self:delete(Paths.join(path, entry.name)) then complete = false end
        end
        if not complete then return false end
    end
    ok = self:attempt(path, fs.remove, path)
    if ok then self.current.changed = true end
    return ok
end

function Operation:record(source, complete, stopped)
    local item = self.current
    if item.failed then
        self.failed = self.failed + 1
    elseif item.skipped then
        self.skipped = self.skipped + 1
    elseif complete then
        self.completed = self.completed + 1
    elseif stopped then
        self.details[#self.details + 1] = "Stopped at " .. source
    end
    if item.changed and not complete then
        self.details[#self.details + 1] = "Partially completed: " .. source
    end
end

function Operation.new(mode, sources, destination, moved)
    local self = setmetatable({
        mode = mode, total = #sources, completed = 0, skipped = 0, failed = 0, details = {},
    }, Operation)
    self.thread = coroutine.create(function()
        for index, source in ipairs(sources) do
            self.index, self.source, self.current = index, source, {}
            self:step(source)
            local complete
            if mode == "delete" then
                complete = self:delete(source)
            else
                complete = self:paste(source, Paths.join(destination, Paths.name(source)))
                if complete and mode == "cut" then moved(source) end
            end
            self:record(source, complete)
            self.current = nil
        end
    end)
    return self
end

function Operation:update(answer, remaining)
    if self.event and self.event.kind ~= "progress" and not answer then return end
    local event = self.event
    local ok, result = coroutine.resume(self.thread, answer, remaining)
    if ok and coroutine.status(self.thread) ~= "dead" then
        self.event = result
        return
    end
    if not ok then
        self.cancelled = result == cancelled
        if self.cancelled and event and event.kind == "error" then
            self.details[#self.details + 1] = event.detail
        elseif not self.cancelled then
            if self.current then self.current.failed = true end
            self.details[#self.details + 1] = tostring(result)
        end
        if self.current then self:record(self.source, false, self.cancelled) end
        if self.backup then self.details[#self.details + 1] = "Backup retained: " .. self.backup end
    end
    local leftover = self:cleanup()
    if leftover then self.details[#self.details + 1] = leftover end
    self.event, self.thread = nil, nil
    return true
end

return Operation
