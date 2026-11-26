local Label = require("lib.ui.label")
local Panel = require("lib.ui.panel")
local Button = setmetatable({}, {__index = Panel})
Button.__index = Button

function Button.new(rect, text, action, style)
    style = style or {}
    local self = setmetatable(Panel.new(rect, style.background, style.border), Button)
    self.action, self.enabled, self.pressed = action, true, false
    self.pressed_background = style.pressed_background
    if text then
        local padding = style.padding or 0
        self.label = self:add(Label.new({x = padding, y = 0, width = rect.width - padding * 2,
            height = rect.height}, text, style.color, style.align or "center"))
    end
    return self
end

function Button:set_text(text)
    self.label.text = text
end

function Button:set_pressed(pressed)
    self.pressed = pressed
end

function Button:draw_self(x, y)
    if self.label then
        local rect = self.label.rect
        rect.width, rect.height = self.rect.width - rect.x * 2, self.rect.height
    end
    Panel.draw_self(self, x, y, self.pressed and self.pressed_background)
end

function Button:hit_target(x, y)
    if not self.enabled or not self.action then return end
    return {x = x, y = y, width = self.rect.width, height = self.rect.height, action = self.action, node = self}
end

return Button
