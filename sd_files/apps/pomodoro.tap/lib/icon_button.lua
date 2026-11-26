local Button = require("button")

local IconButton = setmetatable({}, {__index = Button})
IconButton.__index = IconButton

function IconButton.new(x, y, width, height, sprite, transparent, action)
    local button = Button.new(x, y, width, height, nil, action)
    button.sprite = sprite
    button.transparent = transparent
    return setmetatable(button, IconButton)
end

function IconButton:draw_content()
    gfx.spr(self.sprite, self.x + (self.width - self.sprite.width) // 2,
        self.y + (self.height - self.sprite.height) // 2, self.transparent)
end

return IconButton
