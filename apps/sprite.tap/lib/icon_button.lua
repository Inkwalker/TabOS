local Button = require("button")

local IconButton = {}

function IconButton.new(x, y, width, height, icon, colors, action)
    local icon_x = x + (width - icon.width) // 2
    local icon_y = y + (height - icon.height) // 2
    local content = {
        draw = function()
            -- TabOS flattens transparent PNG pixels against black.
            gfx.spr(icon, icon_x, icon_y, 0)
        end,
    }
    return Button.new(x, y, width, height, content, colors, action)
end

return IconButton
