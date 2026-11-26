local Node = require("lib.ui.node")
local Panel = setmetatable({}, {__index = Node})
Panel.__index = Panel

function Panel.new(rect, background, border)
    local self = setmetatable(Node.new(rect), Panel)
    self.background, self.border = background, border
    return self
end

function Panel:draw_self(x, y, background)
    local rect = self.rect
    local fill = background or self.background
    if fill then gfx.rectfill(x, y, rect.width, rect.height, fill) end
    if self.border then gfx.rect(x, y, rect.width, rect.height, self.border) end
end

return Panel
