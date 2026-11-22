local PixelCursor = require("pixel_cursor")

local PipetteTool = {icon_path = "spr/pipette.png"}
PipetteTool.__index = PipetteTool

function PipetteTool.new(set_color, cursor_color)
    return setmetatable({set_color = set_color, cursor = PixelCursor.new(cursor_color)}, PipetteTool)
end

function PipetteTool:activate(canvas)
    self.cursor:activate(canvas)
end

function PipetteTool:draw(canvas)
    self.cursor:draw(canvas)
end

function PipetteTool:sample(canvas)
    self.set_color(canvas:pixel_color(self.cursor.x, self.cursor.y))
    return true
end

function PipetteTool:begin_drag(canvas, x, y)
    local px, py = canvas:pixel_at(x, y)
    if px == nil then return end

    self.cursor.x, self.cursor.y = px, py
    return self:sample(canvas)
end

function PipetteTool:drag(canvas, motion)
    return self:begin_drag(canvas, motion.x, motion.y)
end

function PipetteTool:key_pressed(canvas, key)
    if key == "`" then return self:sample(canvas) end
    return self.cursor:move(canvas, key)
end

return PipetteTool
