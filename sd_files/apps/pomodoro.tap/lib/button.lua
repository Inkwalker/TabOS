local colors = require("theme")

local Button = {}
Button.__index = Button

function Button.new(x, y, width, height, text, action)
    return setmetatable({
        x = x, y = y, width = width, height = height,
        text = text, action = action,
    }, Button)
end

function Button:contains(contact)
    return contact.x >= self.x and contact.x < self.x + self.width
        and contact.y >= self.y and contact.y < self.y + self.height
end

function Button:draw(pressed, fill, color, border)
    local x, y, w, h = self.x, self.y, self.width, self.height
    gfx.rectfill(x, y, w, h, pressed and colors.pressed or fill)
    if border then gfx.rect(x, y, w, h, border) end
    self:draw_content(pressed and colors.text or color)
end

function Button:draw_content(color)
    gfx.print(self.x + (self.width - #self.text * 6) // 2, self.y + (self.height - 8) // 2,
        self.text, color)
end

return Button
