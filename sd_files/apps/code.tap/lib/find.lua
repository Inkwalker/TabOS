local Document = require("document")
local Find = {}
Find.__index = Find

function Find.new()
    return setmetatable({query = "", caret = 1}, Find)
end

function Find:move(step)
    self.caret = math.max(1, math.min(#self.query + 1, self.caret + step))
end

function Find:edit(text)
    local query, caret = self.query, self.caret
    local offset = 1
    while offset <= #text do
        local char = text:byte(offset)
        if char == 8 then
            if caret > 1 then
                query = query:sub(1, caret - 2) .. query:sub(caret)
                caret = caret - 1
            end
        elseif char == 127 then
            query = query:sub(1, caret - 1) .. query:sub(caret + 1)
        else
            local _, last = text:find("^[\t -~]+", offset)
            if last then
                local inserted = text:sub(offset, math.min(last, offset + Document.limit - #query - 1))
                query = query:sub(1, caret - 1) .. inserted .. query:sub(caret)
                caret = caret + #inserted
                offset = last
            end
        end
        offset = offset + 1
    end
    self.query, self.caret = query, caret
end

function Find:display(width)
    local first, column = self.caret, 0
    while first > 1 and column < width - 1 do
        first = first - 1
        column = column + (self.query:byte(first) == 9 and 2 or 1)
    end
    local clipped = math.max(0, column - width + 1)
    local text = self.query:sub(first, first + width - 1):gsub("\t", "\\t")
    return text:sub(clipped + 1, clipped + width), column - clipped
end

local function match_in(line, query, first, last, reversed)
    last = math.min(last, #line - #query + 1)
    if first > last then return end
    local found = line:find(query, first, true)
    if not found or found > last then return end
    if not reversed then return found end
    local from_end = line:reverse():find(reversed, #line - last - #query + 2, true)
    return #line - from_end - #query + 2
end

function Find:select(doc, backwards)
    local query = self.query
    if query == "" then return nil, "Enter text to find" end

    local row, index = doc.row, doc.index
    local first, start, last, stop = doc:selection()
    local on_match = first and first == last and stop - start == #query
        and doc.lines[first]:sub(start, stop - 1) == query
    if on_match then row, index = first, start end

    local count = #doc.lines
    local step = backwards and -1 or 1
    local reversed = backwards and query:reverse()
    local boundary = index + (not backwards and on_match and 1 or 0)
    for offset = 0, count do
        local unwrapped = row + offset * step
        local candidate = (unwrapped - 1) % count + 1
        local line = doc.lines[candidate]
        local lower, upper = 1, #line
        if offset == 0 then
            if backwards then upper = boundary - 1 else lower = boundary end
        elseif offset == count then
            if backwards then lower = boundary else upper = boundary - 1 end
        end
        local found = match_in(line, query, lower, upper, reversed)
        if found then
            doc:select_range(candidate, found, found + #query)
            return true, unwrapped ~= candidate and "Search wrapped" or nil
        end
    end
    return nil, "No matches"
end

return Find
