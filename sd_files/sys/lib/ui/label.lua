local Node = require("lib.ui.node")
local Label = setmetatable({}, {__index = Node})
Label.__index = Label

local glyph_width, glyph_height = 6, 8

local function fit(text, limit)
    if #text <= limit then return text end
    if limit < 3 then return text:sub(1, limit) end
    return text:sub(1, limit - 3) .. "..."
end

function Label.new(rect, text, color, align)
    local self = setmetatable(Node.new(rect), Label)
    self.text, self.color, self.align = text, color, align
    return self
end

function Label:draw_self(x, y)
    local rect = self.rect
    local limit = rect.width // glyph_width
    if limit < 1 or rect.height < glyph_height then return end
    local text = fit(self.text, limit)
    if self.align == "center" then x = x + (rect.width - #text * glyph_width) // 2 end
    y = y + (rect.height - glyph_height) // 2
    gfx.print(x, y, text, self.color)
end

return Label
