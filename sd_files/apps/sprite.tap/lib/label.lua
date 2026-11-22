local Label = {}
Label.__index = Label

local glyph_width = 6

function Label.new(x, y, width, text, color, alignment)
    local label = setmetatable({x = x, y = y, width = width, color = color,
        alignment = alignment, visible = true}, Label)
    label:set_text(text)
    return label
end

function Label:set_text(text)
    text = text:gsub("%c", " ")
    local limit = self.width // glyph_width
    if #text > limit then
        if limit >= 3 then
            text = text:sub(1, limit - 3) .. "..."
        else
            text = text:sub(1, limit)
        end
    end
    self.text = text
end

function Label:draw(color)
    if not self.visible then return end
    local x = self.x
    if self.alignment == "center" then
        x = x + (self.width - #self.text * glyph_width) // 2
    end
    gfx.print(x, self.y, self.text, color or self.color)
end

return Label
