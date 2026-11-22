local Label = require("label")

local Button = {}
Button.__index = Button

function Button.new(x, y, width, height, content, colors, action)
    if type(content) == "string" then
        content = Label.new(x, y + (height - 8) // 2, width, content, colors.text, "center")
    end
    return setmetatable({
        x = x, y = y, width = width, height = height,
        content = content,
        colors = colors, enabled = true, action = action,
    }, Button)
end

function Button:draw()
    local colors = self.colors
    gfx.rectfill(self.x, self.y, self.width, self.height, colors.background)
    self.content:draw(self.enabled and colors.text or colors.disabled_text)
end

function Button:press(touch)
    if self.enabled and touch ~= nil
        and touch.x >= self.x and touch.x < self.x + self.width
        and touch.y >= self.y and touch.y < self.y + self.height then
        self.action()
        return true
    end
    return false
end

return Button
