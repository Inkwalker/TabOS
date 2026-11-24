local Button = require("button")

local InputField = {}
InputField.__index = InputField

function InputField.new(x, y, width, height, colors, options)
    local self = setmetatable({
        value = "", accept = options.accept, max_length = options.max_length,
        focus_color = colors.text,
    }, InputField)
    self.button = Button.new(x, y, width, height, "", colors, function() self:select() end)
    return self
end

function InputField:set_value(value)
    self.value = value
    self.button.content:set_text(value)
end

function InputField:select()
    self.replace_value = true
end

function InputField:draw(focused)
    local button = self.button
    button:draw()
    if focused then
        gfx.rect(button.x, button.y, button.width, button.height, self.focus_color)
    end
end

function InputField:press(touch)
    return self.button:press(touch)
end

function InputField:update()
    local text = input.txt()
    if input.keyp(3, 14) and not text:find("\b", 1, true) then text = text .. "\b" end
    local value = self.value
    for char in text:gmatch(".") do
        if char == "\b" or char:match(self.accept) then
            if self.replace_value then value = "" end
            self.replace_value = false
            if char == "\b" then
                value = value:sub(1, -2)
            elseif #value < self.max_length then
                value = value .. char
            end
        end
    end
    if value == self.value then return false end
    self:set_value(value)
    return true
end

return InputField
