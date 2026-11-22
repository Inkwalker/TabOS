local Encoding = {}

-- FatFs returns UTF-8 filenames. The Lua VM does not load the UTF-8 library.
function Encoding.decode(text, index)
    local lead = text:byte(index)
    if not lead then return nil end
    if lead < 0x80 then return lead, index + 1 end

    local value, count, minimum
    if lead >= 0xc2 and lead <= 0xdf then
        value, count, minimum = lead & 0x1f, 2, 0x80
    elseif lead >= 0xe0 and lead <= 0xef then
        value, count, minimum = lead & 0x0f, 3, 0x800
    elseif lead >= 0xf0 and lead <= 0xf4 then
        value, count, minimum = lead & 0x07, 4, 0x10000
    else
        return nil
    end
    for offset = 1, count - 1 do
        local byte = text:byte(index + offset)
        if not byte or byte < 0x80 or byte >= 0xc0 then return nil end
        value = (value << 6) | (byte & 0x3f)
    end
    if value < minimum or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff) then return nil end
    return value, index + count
end

function Encoding.encode(value)
    if value < 0x80 then return string.char(value) end
    local last = 0x80 | (value & 0x3f)
    if value < 0x800 then return string.char(0xc0 | (value >> 6), last) end
    local second_last = 0x80 | ((value >> 6) & 0x3f)
    if value < 0x10000 then return string.char(0xe0 | (value >> 12), second_last, last) end
    return string.char(0xf0 | (value >> 18), 0x80 | ((value >> 12) & 0x3f), second_last, last)
end

function Encoding.utf16_length(text)
    if not text:find("[\128-\255]") then return #text end
    local index, length = 1, 0
    while index <= #text do
        local value, next_index = Encoding.decode(text, index)
        if not value then return nil end
        length = length + (value > 0xffff and 2 or 1)
        index = next_index
    end
    return length
end

-- Filename fields contain only validated filenames and ASCII keyboard input.
function Encoding.previous(text, index)
    index = math.max(1, index - 1)
    while index > 1 and (text:byte(index) & 0xc0) == 0x80 do
        index = index - 1
    end
    return index
end

function Encoding.next(text, index)
    local _, next_index = Encoding.decode(text, index)
    return next_index or index
end

return Encoding
