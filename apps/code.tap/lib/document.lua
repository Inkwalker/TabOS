local History = require("history")
local Syntax = require("syntax")
local Document = {limit = 64 * 1024}
Document.__index = Document

local function tab_width(column)
    return 4 - column % 4
end

local function column_at(line, index)
    local start, column = 1, 0
    local tab = line:find("\t", start, true)
    while tab and tab < index do
        column = column + tab - start
        column = column + tab_width(column)
        start = tab + 1
        tab = line:find("\t", start, true)
    end
    return column + index - start
end

local function index_at(line, column)
    local start, display = 1, 0
    local tab = line:find("\t", start, true)
    while tab do
        local before_tab = display + tab - start
        if column <= before_tab then return start + math.floor(column + 0.5) - display end
        display = before_tab + tab_width(before_tab)
        if column < display then
            return (column - before_tab) * 2 < display - before_tab and tab or tab + 1
        end
        start = tab + 1
        tab = line:find("\t", start, true)
    end
    return math.min(#line + 1, start + math.floor(column + 0.5) - display)
end

function Document.new(bytes, history)
    local saved = bytes
    bytes = bytes or ""
    if #bytes > Document.limit then return nil, "File exceeds 64 KiB" end
    local text, pairs = bytes:gsub("\r\n", "\n")
    if text:find("[^\32-\126\t\n]") then
        return nil, "Use ASCII text with LF or CRLF"
    end
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    if pairs > 0 and pairs ~= #lines - 1 then
        return nil, "Mixed LF and CRLF line endings"
    end
    history = history or History.new()
    local doc = setmetatable({
        lines = lines, eol = pairs > 0 and "\r\n" or "\n", size = #bytes,
        row = 1, index = 1, column = 0, saved = saved, modified = saved == nil,
        top = 1, left = 0, history = history, undo = {}, redo = {},
    }, Document)
    history:attach(doc)
    return doc
end

function Document:serialize()
    return table.concat(self.lines, self.eol)
end

function Document:mark_saved(bytes)
    self.saved, self.modified = bytes, false
    self:break_group()
end

function Document:break_group()
    self.typing = false
end

function Document:selection()
    local anchor = self.anchor
    if not anchor then return end
    if anchor.row < self.row or (anchor.row == self.row and anchor.index < self.index) then
        return anchor.row, anchor.index, self.row, self.index
    end
    if anchor.row ~= self.row or anchor.index ~= self.index then
        return self.row, self.index, anchor.row, anchor.index
    end
end

function Document:column_at(row, index)
    local line = self.lines[row]
    return column_at(line, index or #line + 1)
end

function Document:set_caret(row, index)
    self.row, self.index = row, index
    self.column = self:column_at(row, index)
end

function Document:place(row, column, word)
    self:break_group()
    self.anchor, self.preferred = nil, nil
    row = math.min(#self.lines, row)
    local line = self.lines[row]
    local index = index_at(line, column)
    if word then
        -- Choose the character under the contact, even past its midpoint.
        local hit = column_at(line, index) > column and index - 1 or index
        local char = line:sub(hit, hit)
        if char:match("[A-Za-z0-9_]") then
            local first = hit
            while first > 1 and line:sub(first - 1, first - 1):match("[A-Za-z0-9_]") do
                first = first - 1
            end
            local _, last = line:find("[A-Za-z0-9_]+", hit)
            self.anchor, index = {row = row, index = first}, last + 1
        elseif char ~= "" and not char:match("%s") then
            self.anchor, index = {row = row, index = hit}, hit + 1
        end
    end
    self:set_caret(row, index)
end

function Document:select_all()
    self:break_group()
    self.anchor, self.preferred = {row = 1, index = 1}, nil
    self:set_caret(#self.lines, #self.lines[#self.lines] + 1)
end

function Document:select_range(row, first, stop)
    self:break_group()
    self.anchor, self.preferred = {row = row, index = first}, nil
    self:set_caret(row, stop)
end

function Document:highlighting()
    self.syntax = self.syntax or Syntax.new(self.lines)
    return self.syntax
end

function Document:move(direction, count, extend)
    self:break_group()
    local first, start, last, stop = self:selection()
    if extend then
        self.anchor = self.anchor or {row = self.row, index = self.index}
    else
        self.anchor = nil
        if first and (direction == "left" or direction == "right") then
            self.preferred = nil
            if direction == "left" then self:set_caret(first, start)
            else self:set_caret(last, stop) end
            return
        end
    end
    local row, index = self.row, self.index
    local line = self.lines[row]
    if direction == "left" then
        if index > 1 then
            index = index - 1
        elseif row > 1 then
            row, index = row - 1, #self.lines[row - 1] + 1
        end
    elseif direction == "right" then
        if index <= #line then
            index = index + 1
        elseif row < #self.lines then
            row, index = row + 1, 1
        end
    elseif direction == "line_start" then
        index = 1
    elseif direction == "line_end" then
        index = #line + 1
    else
        local step = direction == "up" and -count or count
        row = math.max(1, math.min(#self.lines, row + step))
        if row == self.row then return end
        self.preferred = self.preferred or self.column
        index = index_at(self.lines[row], self.preferred)
    end
    if direction ~= "up" and direction ~= "down" then self.preferred = nil end
    self:set_caret(row, index)
end

local function range_text(lines, first, start, last, stop)
    if first == last then return lines[first]:sub(start, stop - 1) end
    local parts = {lines[first]:sub(start)}
    table.move(lines, first + 1, last - 1, 2, parts)
    parts[last - first + 1] = lines[last]:sub(1, stop - 1)
    return table.concat(parts, "\n")
end

function Document:copy()
    local first, start, last, stop = self:selection()
    if first then return range_text(self.lines, first, start, last, stop) end
end

local function snapshot(doc)
    return {row = doc.row, index = doc.index, anchor = doc.anchor, preferred = doc.preferred}
end

local function restore(doc, position)
    doc.anchor, doc.preferred = position.anchor, position.preferred
    doc:set_caret(position.row, position.index)
end

local function splice(lines, first, start, last, stop, inserted)
    local left, right = lines[first]:sub(1, start - 1), lines[last]:sub(stop)
    if not inserted:find("\n", 1, true) and first == last then
        lines[first] = left .. inserted .. right
        return first, start + #inserted
    end

    local parts = {}
    for line in (inserted .. "\n"):gmatch("([^\n]*)\n") do
        parts[#parts + 1] = line
    end
    parts[1] = left .. parts[1]
    local row, index, old_count = first + #parts - 1, #parts[#parts] + 1, #lines
    parts[#parts] = parts[#parts] .. right
    if row ~= last then
        table.move(lines, last + 1, old_count, row + 1)
        for trailing = old_count, old_count + row - last + 1, -1 do lines[trailing] = nil end
    end
    table.move(parts, 1, #parts, first, lines)
    return row, index
end

local function replace(doc, first, start, last, stop, inserted, breaks)
    local removed = range_text(doc.lines, first, start, last, stop)
    local delta = #inserted - #removed + (breaks - (last - first)) * (#doc.eol - 1)
    if doc.size + delta > Document.limit then return nil, "Edit exceeds 64 KiB" end
    if removed == "" and inserted == "" then return true end
    local before = snapshot(doc)
    local row, index = splice(doc.lines, first, start, last, stop, inserted)
    if doc.syntax then doc.syntax:invalidate(first) end
    doc.anchor, doc.preferred, doc.size = nil, nil, doc.size + delta
    doc:set_caret(row, index)
    return {
        row = first, index = start, last = last, stop = stop, delta = delta,
        removed = removed, inserted = inserted, before = before, after = snapshot(doc),
    }
end

local function replay(doc, edit, reverse)
    if doc.syntax then doc.syntax:invalidate(edit.row) end
    if reverse then
        splice(doc.lines, edit.row, edit.index, edit.after.row, edit.after.index, edit.removed)
        doc.size = doc.size - edit.delta
        restore(doc, edit.before)
    else
        splice(doc.lines, edit.row, edit.index, edit.last, edit.stop, edit.inserted)
        doc.size = doc.size + edit.delta
        restore(doc, edit.after)
    end
end

local function update_modified(self)
    self.modified = not self.saved or self.size ~= #self.saved or self:serialize() ~= self.saved
end

local function edit_range(doc)
    local first, start, last, stop = doc:selection()
    if first then return first, start, last, stop, true end
    return doc.row, doc.index, doc.row, doc.index, false
end

local function expand_tabs(doc, row, index, text)
    if not text:find("\t", 1, true) then return text end
    local column, offset = doc:column_at(row, index), 1
    return (text:gsub("()\t", function(at)
        column = column + at - offset
        local spaces = tab_width(column)
        column, offset = column + spaces, at + 1
        return string.rep(" ", spaces)
    end))
end

-- Keep the input batch atomic while recording separate history groups for
-- newline, deletion, and selection replacement.
function Document:edit(text, time)
    if text:find("[^\32-\126\t\r\n\b\127]") then return nil, "Unsupported keyboard input" end
    local edits, offset = {}, 1
    while offset <= #text do
        local first, start, last, stop, selected = edit_range(self)
        local char = text:sub(offset, offset)
        local inserted, breaks, typing = "", 0, false
        if char == "\r" or char == "\n" then
            inserted, breaks = "\n", 1
        elseif char == "\b" then
            if not selected then
                if start > 1 then start = start - 1
                elseif first > 1 then first, start = first - 1, #self.lines[first - 1] + 1 end
            end
        elseif char == "\127" then
            if not selected then
                if stop <= #self.lines[last] then stop = stop + 1
                elseif last < #self.lines then last, stop = last + 1, 1 end
            end
        else
            local _, ending = text:find("[\t -~]+", offset)
            inserted, typing = expand_tabs(self, first, start, text:sub(offset, ending)), not selected
            offset = ending
        end

        local edit, err = replace(self, first, start, last, stop, inserted, breaks)
        if not edit then
            for i = #edits, 1, -1 do replay(self, edits[i], true) end
            return nil, err
        end
        if edit ~= true then
            edit.typing = typing
            edits[#edits + 1] = edit
        end
        offset = offset + 1
    end
    for _, edit in ipairs(edits) do self.history:record(self, edit, edit.typing, time) end
    if #edits > 0 then update_modified(self) end
    return true
end

-- Clipboard text uses LF internally and preserves literal tabs.
function Document:paste(text)
    if text:find("[^\32-\126\t\n]") then return nil, "Unsupported clipboard text" end
    local first, start, last, stop = edit_range(self)
    local _, breaks = text:gsub("\n", "")
    local edit, err = replace(self, first, start, last, stop, text, breaks)
    if not edit then return nil, err end
    if edit ~= true then
        self.history:record(self, edit, false)
        update_modified(self)
    end
    return true
end

function Document:step_history(reverse)
    self:break_group()
    local from, to = self.redo, self.undo
    if reverse then from, to = to, from end
    local edit = table.remove(from)
    if not edit then return end
    replay(self, edit, reverse)
    to[#to + 1] = edit
    update_modified(self)
    return true
end

function Document.visible_text(line, left, width, with_origins)
    if not line:find("\t", 1, true) then return line:sub(left + 1, left + width), left + 1 end
    local start, display, visible = 1, 0, {}
    local origins = with_origins and {}
    local right = left + width
    while display < right do
        local tab = line:find("\t", start, true)
        local stop = tab or #line + 1
        local end_column = display + stop - start
        local first, last = math.max(left, display), math.min(right, end_column)
        if first < last then
            visible[#visible + 1] = line:sub(start + first - display, start + last - display - 1)
            if origins then
                for column = first, last - 1 do origins[#origins + 1] = start + column - display end
            end
        end
        if not tab or end_column >= right then break end
        display = end_column + tab_width(end_column)
        local spaces = math.min(right, display) - math.max(left, end_column)
        if spaces > 0 then
            visible[#visible + 1] = string.rep(" ", spaces)
            if origins then
                for _ = 1, spaces do origins[#origins + 1] = tab end
            end
        end
        start = tab + 1
    end
    return table.concat(visible), origins and origins[1] or left + 1, origins
end

return Document
