local Document = {}
Document.__index = Document
Document.limit = 64 * 1024

function Document.new(bytes, is_new)
    if #bytes > Document.limit then return nil, "File exceeds 64 KiB" end
    local eol = bytes:find("\r\n", 1, true) and "\r\n" or "\n"
    local text = bytes:gsub("\r\n", "\n")
    if text:find("[^\32-\126\t\n]") or (eol == "\r\n" and bytes:gsub("\r\n", ""):find("\n", 1, true)) then
        return nil, "Unsupported bytes or mixed line endings"
    end
    return setmetatable({text = text, eol = eol, cursor = 0, saved = is_new and nil or bytes,
        is_new = is_new, undo_groups = {}, redo_groups = {}, history_bytes = 0}, Document)
end

function Document:serialize()
    return self.eol == "\n" and self.text or self.text:gsub("\n", "\r\n")
end

function Document:dirty()
    return self.is_new or self:serialize() ~= self.saved
end

-- Cursor offsets count document characters before the caret, starting at zero.
function Document:position()
    local before = self.text:sub(1, self.cursor)
    local _, breaks = before:gsub("\n", "")
    local start = before:match(".*\n()") or 1
    return breaks + 1, self:column(before:sub(start)), start - 1
end

function Document:column(text)
    local col = 0
    for char in text:gmatch(".") do
        col = char == "\t" and (col + 4 - col % 4) or col + 1
    end
    return col
end

function Document:end_group()
    self.typing_group = nil
end

function Document:mark_saved()
    self.saved, self.is_new = self:serialize(), false
    self:end_group()
end

function Document:replace(at, count, inserted, kind, now)
    local removed = self.text:sub(at + 1, at + count)
    if removed == inserted then return true end
    local result = self.text:sub(1, at) .. inserted .. self.text:sub(at + count + 1)
    local size = #result
    if self.eol == "\r\n" then
        local _, breaks = result:gsub("\n", "")
        size = size + breaks
    end
    if size > Document.limit then return nil, "Edit exceeds 64 KiB" end
    for _, group in ipairs(self.redo_groups) do
        self.history_bytes = self.history_bytes - #group.removed - #group.inserted
    end
    self.redo_groups = {}
    local last = self.undo_groups[#self.undo_groups]
    if kind == "typing" and last and last == self.typing_group and #removed == 0
        and at == last.at + #last.inserted and now and self.last_typed
        and now - self.last_typed < 0.75 then
        last.inserted = last.inserted .. inserted
        last.after = at + #inserted
    else
        last = {at = at, removed = removed, inserted = inserted, before = self.cursor,
            after = at + #inserted}
        self.undo_groups[#self.undo_groups + 1] = last
    end
    self.typing_group = kind == "typing" and last or nil
    self.last_typed = now
    self.history_bytes = self.history_bytes + #removed + #inserted
    while #self.undo_groups + #self.redo_groups > 128 or self.history_bytes > 128 * 1024 do
        local oldest = table.remove(self.undo_groups, 1)
        self.history_bytes = self.history_bytes - #oldest.removed - #oldest.inserted
    end
    self.text, self.cursor, self.preferred = result, at + #inserted, nil
    return true
end

function Document:insert(text, kind, now)
    if text:find("[^\32-\126\n]") then return nil, "Unsupported input" end
    return self:replace(self.cursor, 0, text, kind, now)
end

function Document:tab()
    local _, col = self:position()
    return self:insert(string.rep(" ", 4 - col % 4))
end

function Document:erase(backward)
    self:end_group()
    if backward and self.cursor > 0 then
        return self:replace(self.cursor - 1, 1, "")
    elseif not backward and self.cursor < #self.text then
        return self:replace(self.cursor, 1, "")
    end
    return true
end

function Document:move(direction, rows)
    self:end_group()
    if direction == "left" or direction == "right" then
        self.cursor = math.max(0, math.min(#self.text, self.cursor + (direction == "left" and -1 or 1)))
        self.preferred = nil
        return
    end
    local _, col, start = self:position()
    if direction == "line_start" or direction == "line_end" then
        self.cursor = direction == "line_start" and start
            or ((self.text:find("\n", start + 1, true) or (#self.text + 1)) - 1)
        self.preferred = nil
        return
    end
    self.preferred = self.preferred or col
    for _ = 1, rows or 1 do
        if direction == "up" then
            if start == 0 then break end
            start = (self.text:sub(1, start - 1):match(".*\n()") or 1) - 1
        else
            local ending = self.text:find("\n", start + 1, true)
            if not ending then break end
            start = ending
        end
    end
    local offset, display = start, 0
    while offset < #self.text and display < self.preferred do
        local char = self.text:sub(offset + 1, offset + 1)
        if char == "\n" then break end
        display = char == "\t" and display + 4 - display % 4 or display + 1
        offset = offset + 1
    end
    self.cursor = offset
end

function Document:undo()
    self:end_group()
    local group = table.remove(self.undo_groups)
    if not group then return false end
    self.text = self.text:sub(1, group.at) .. group.removed .. self.text:sub(group.at + #group.inserted + 1)
    self.cursor, self.preferred = group.before, nil
    self.redo_groups[#self.redo_groups + 1] = group
    return true
end

function Document:redo()
    self:end_group()
    local group = table.remove(self.redo_groups)
    if not group then return false end
    self.text = self.text:sub(1, group.at) .. group.inserted .. self.text:sub(group.at + #group.removed + 1)
    self.cursor, self.preferred = group.after, nil
    self.undo_groups[#self.undo_groups + 1] = group
    return true
end

function Document:find(query, direction, inclusive)
    self:end_group()
    if query == "" or query:find("\n", 1, true) then return nil end
    local first, previous, next_match, last
    local from = 1
    while true do
        local match = self.text:find(query, from, true)
        if not match then break end
        local offset = match - 1
        first, last = first or offset, offset
        if offset < self.cursor or (inclusive and offset == self.cursor) then previous = offset end
        if not next_match and (offset > self.cursor or (inclusive and offset == self.cursor)) then
            next_match = offset
        end
        from = match + 1
    end
    local result = direction == -1 and (previous or last) or (next_match or first)
    if result then self.cursor, self.preferred = result, nil end
    return result
end

return Document
