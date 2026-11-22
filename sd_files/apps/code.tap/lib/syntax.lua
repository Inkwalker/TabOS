local Syntax = {}
Syntax.__index = Syntax

local keywords = {}
for word in ("and break do else elseif end false for function global goto if in local nil not or repeat return then true until while"):gmatch("%S+") do
    keywords[word] = true
end

local checkpoint_rows = 32
local function ignore() end

local function long_open(line, first)
    local _, last = line:find("^%[=*%[", first)
    if last then return last + 1, last - first end
end

local function long_end(line, first, level)
    while true do
        local bracket = line:find("]", first, true)
        if not bracket then return end
        local _, last = line:find("^=*", bracket + 1)
        first = last + 1
        if first - bracket == level and line:byte(first) == 93 then return first end
    end
end

-- Lua allows comments and newlines before a parameter or argument list.
local function function_name(lines, row, first)
    local level
    while row <= #lines do
        local line = lines[row]
        if level then
            local last = long_end(line, first, level)
            first = (last or #line) + 1
            if last then level = nil end
        else
            local next_byte = line:find("[^ \t]", first)
            if next_byte then
                local char = line:sub(next_byte, next_byte)
                if char == "-" and line:byte(next_byte + 1) == 45 then
                    local after
                    after, level = long_open(line, next_byte + 2)
                    first = after or #line + 1
                else
                    local args = char == "(" or char == "{" or char == '"' or char == "'"
                        or (char == "[" and long_open(line, next_byte) ~= nil)
                    return args, row
                end
            else
                first = #line + 1
            end
        end
        if first > #line then row, first = row + 1, 1 end
    end
    return false, #lines
end

local function short_string(line, first, state, paint)
    local quote = state:sub(1, 1)
    local size = #line
    if #state == 2 then
        local _, last = line:find("^%s*", first)
        paint(first, last, "e")
        if last == size then return size + 1, state end
        first = last + 1
    end
    while first <= size do
        local mark = line:find("[\\" .. quote .. "]", first)
        if not mark then
            paint(first, size, "s")
            return size + 1, false
        end
        if line:sub(mark, mark) == quote then
            paint(first, mark, "s")
            return mark + 1, false
        end
        paint(first, mark - 1, "s")
        if mark == size then
            paint(mark, mark, "e")
            return size + 1, quote
        end
        local escape = line:sub(mark + 1, mark + 1)
        local _
        local last = mark + 1
        if escape == "z" then
            _, last = line:find("^%s*", last + 1)
            if last == size then
                paint(mark, last, "e")
                return size + 1, quote .. "z"
            end
        elseif escape == "x" then
            _, last = line:find("^%x?%x?", last + 1)
        elseif escape == "u" then
            local _, ending = line:find("^%{%x+%}", last + 1)
            last = ending or last
        elseif escape:match("%d") then
            _, last = line:find("^%d?%d?", last + 1)
        end
        paint(mark, last, "e")
        first = last + 1
    end
    return first, false
end

local function number_end(line, first)
    local _, last = line:find("^0[xX]%x*", first)
    local hex = last ~= nil
    local digits = hex and "^%x*" or "^%d*"
    if not last then _, last = line:find(digits, first) end
    if line:byte(last + 1) == 46 and line:byte(last + 2) ~= 46 then
        _, last = line:find(digits, last + 2)
    end
    local _, exponent = line:find(hex and "^[pP][+-]?%d+" or "^[eE][+-]?%d+", last + 1)
    return exponent or last
end

local function scan(line, state, paint, limit)
    if #line == 0 and type(state) == "string" and #state == 1 then return false end
    local first = 1
    while first <= limit do
        if type(state) == "number" then
            local last = long_end(line, first, math.abs(state))
            paint(first, last or #line, state < 0 and "c" or "s")
            if not last then return state end
            first, state = last + 1, false
        elseif state then
            first, state = short_string(line, first, state, paint)
        else
            local char = line:sub(first, first)
            if char == "-" and line:byte(first + 1) == 45 then
                local after, level = long_open(line, first + 2)
                if not after then
                    paint(first, #line, "c")
                    return false
                end
                paint(first, after - 1, "c")
                first, state = after, -level
            elseif char == "[" then
                local after, level = long_open(line, first)
                paint(first, after and after - 1 or first, after and "s" or "o")
                first, state = after or first + 1, level or false
            elseif char == '"' or char == "'" then
                paint(first, first, "s")
                state = first < #line and char or false
                first = first + 1
            elseif char:match("[%a_]") then
                local _, last = line:find("^[%w_]+", first)
                local keyword = last - first < 8 and keywords[line:sub(first, last)]
                paint(first, last, keyword and "k" or "v")
                first = last + 1
            elseif char:match("%d") or (char == "." and line:find("^%.%d", first)) then
                local last = number_end(line, first)
                paint(first, last, "n")
                first = last + 1
            elseif char == "." then
                local _, last = line:find("^%.%.?%.?", first)
                paint(first, last, "o")
                first = last + 1
            elseif char:match("%s") then
                local _, last = line:find("^%s+", first)
                first = last + 1
            else
                paint(first, first, "o")
                first = first + 1
            end
        end
    end
    return state
end

function Syntax.new(lines)
    return setmetatable({lines = lines, checkpoints = {[1] = false}, last_checkpoint = 1, recent = {}}, Syntax)
end

function Syntax:invalidate(row)
    while self.last_checkpoint > row do
        self.checkpoints[self.last_checkpoint] = nil
        self.last_checkpoint = self.last_checkpoint - checkpoint_rows
    end
    for slot, entry in pairs(self.recent) do
        if entry.row >= row or (entry.through and entry.through >= row) then self.recent[slot] = nil end
    end
end

function Syntax:checkpoint(row, state)
    if row == self.last_checkpoint + checkpoint_rows then
        self.checkpoints[row], self.last_checkpoint = state, row
    end
end

function Syntax:before(row)
    local previous = self.recent[(row - 1) % checkpoint_rows]
    if previous and previous.row == row - 1 then return previous.after end

    local checkpoint = math.min(1 + (row - 1) // checkpoint_rows * checkpoint_rows, self.last_checkpoint)
    local state = self.checkpoints[checkpoint]
    for index = checkpoint, row - 1 do
        local line = self.lines[index]
        state = scan(line, state, ignore, #line)
        self:checkpoint(index + 1, state)
    end
    return state
end

-- Only retain the visible byte colors of recent lines and sparse lexer states.
function Syntax:colors(row, first, last)
    local slot = row % checkpoint_rows
    local entry = self.recent[slot]
    local line = self.lines[row]
    if not entry or entry.row ~= row then
        entry = {row = row, before = self:before(row)}
        self.recent[slot] = entry
    end
    if entry.first == first and entry.last == last then return entry.colors end

    local colors = {}
    for index = 1, last - first + 1 do colors[index] = "p" end
    local through = row
    local after = scan(line, entry.before, function(start, stop, color)
        local from, to = math.max(start, first), math.min(stop, last)
        if from > to then return end
        if color == "v" then
            local is_function, looked_through = function_name(self.lines, row, stop + 1)
            through = math.max(through, looked_through)
            if is_function then color = "f" end
        end
        for index = from, to do colors[index - first + 1] = color end
    end, entry.after == nil and #line or last)
    if entry.after == nil then
        entry.after = after
        self:checkpoint(row + 1, after)
    end
    entry.first, entry.last, entry.colors, entry.through = first, last, table.concat(colors), through
    return entry.colors
end

return Syntax
