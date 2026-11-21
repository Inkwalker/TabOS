local History = {}
History.__index = History

local budget = 2 * 1024 * 1024
local entry_overhead = 64
local file_header = "<c4I2I2I4I4i4"
local entry_size_format = "<I4"
local tool_header = "<I1I1"
local file_header_size = string.packsize(file_header)
local entry_size_bytes = string.packsize(entry_size_format)
local tool_header_size = string.packsize(tool_header)

function History.new(handlers)
    return setmetatable({
        handlers = handlers, entries = {}, first = 1, last = 0, cursor = 0, saved = 0, bytes = 0,
    }, History)
end

function History:is_dirty()
    return self.cursor ~= self.saved
end

function History:mark_saved()
    self.saved = self.cursor
end

function History:mark_dirty()
    self.saved = nil
end

function History:needs_checkpoint()
    return self:is_dirty() or self.first <= self.last
end

function History:record(tool, payload)
    if #payload == 0 then return end
    -- A saved revision becomes unreachable when its redo branch is replaced.
    if self.saved and self.saved > self.cursor then self.saved = nil end
    for index = self.last, self.cursor + 1, -1 do
        self.bytes = self.bytes - #self.entries[index] - entry_overhead
        self.entries[index] = nil
    end

    self.cursor = self.cursor + 1
    self.last = self.cursor
    local entry = string.pack(tool_header, tool.history_id, tool.history_version) .. payload
    self.entries[self.last] = entry
    self.bytes = self.bytes + #entry + entry_overhead
    while self.bytes > budget do
        self.bytes = self.bytes - #self.entries[self.first] - entry_overhead
        self.entries[self.first] = nil
        self.first = self.first + 1
    end
    if self.saved and self.saved < self.first - 1 then self.saved = nil end
end

function History:step(canvas, undo)
    local index = undo and self.cursor or self.cursor + 1
    local entry = self.entries[index]
    if not entry then return false end

    local id, version, payload_start = string.unpack(tool_header, entry)
    self.handlers[id].apply_history(canvas, version, entry:sub(payload_start), undo)
    self.cursor = self.cursor + (undo and -1 or 1)
    return true
end

function History:write(file, width, height)
    -- Serialize positions relative to the oldest reachable revision.
    local base = self.first - 1
    local saved = self.saved and self.saved - base or -1
    local ok, err = file:write(string.pack(file_header, "SPH1", width, height,
        self.last - base, self.cursor - base, saved))
    if not ok then return nil, err end

    for index = self.first, self.last do
        local entry = self.entries[index]
        ok, err = file:write(string.pack(entry_size_format, #entry), entry)
        if not ok then return nil, err end
    end
    return true
end

function History.read(file, handlers, width, height)
    local invalid = "Invalid sprite history checkpoint"
    local header, err = file:read(file_header_size)
    if not header or #header ~= file_header_size then return nil, err or invalid end
    local magic, recorded_width, recorded_height, count, cursor, saved = string.unpack(file_header, header)
    if magic ~= "SPH1" or recorded_width ~= width or recorded_height ~= height
        or count < 0 or count > budget // entry_overhead or cursor < 0 or cursor > count
        or saved < -1 or saved > count then
        return nil, invalid
    end

    local history = History.new(handlers)
    for index = 1, count do
        header, err = file:read(entry_size_bytes)
        if not header or #header ~= entry_size_bytes then return nil, err or invalid end
        local size = string.unpack(entry_size_format, header)
        if size <= tool_header_size or size > budget - history.bytes - entry_overhead then return nil, invalid end
        local entry
        entry, err = file:read(size)
        if not entry or #entry ~= size then return nil, err or invalid end
        local id, version, payload_start = string.unpack(tool_header, entry)
        local handler = handlers[id]
        if not handler then return nil, "Unknown tool in sprite history checkpoint" end
        if not handler.validate_history(version, entry:sub(payload_start), width * height) then return nil, invalid end
        history.entries[index] = entry
        history.bytes = history.bytes + size + entry_overhead
    end
    local trailing
    trailing, err = file:read(1)
    if trailing or err then return nil, err or invalid end

    history.last, history.cursor = count, cursor
    history.saved = saved >= 0 and saved or nil
    return history
end

return History
