local ToolManager = {}
ToolManager.__index = ToolManager

function ToolManager.new(canvas)
    return setmetatable({canvas = canvas}, ToolManager)
end

function ToolManager:cancel_drag()
    if not self.contact then return end
    self.contact = nil
    if self.active.end_drag then self.active:end_drag(self.canvas) end
end

function ToolManager:set_active(tool)
    if self.active == tool then return end
    self:cancel_drag()
    self.active = tool
    if tool and tool.activate then tool:activate(self.canvas) end
end

function ToolManager:update_touch(contacts, press)
    local tool, canvas = self.active, self.canvas
    if not tool then return end

    local previous = self.contact
    if previous then
        for _, touch in ipairs(contacts) do
            if touch.id == previous.id then
                self.contact = touch
                if tool.drag and (touch.x ~= previous.x or touch.y ~= previous.y) then
                    return tool:drag(canvas, {
                        x = touch.x - canvas.x, y = touch.y - canvas.y,
                        dx = touch.x - previous.x, dy = touch.y - previous.y,
                    })
                end
                return
            end
        end
        self:cancel_drag()
    elseif press and canvas:contains(press.x, press.y) then
        self.contact = press
        if tool.begin_drag then return tool:begin_drag(canvas, press.x - canvas.x, press.y - canvas.y) end
    end
end

function ToolManager:key_pressed(key)
    if self.active and self.active.key_pressed then
        return self.active:key_pressed(self.canvas, key)
    end
end

function ToolManager:draw()
    if self.active and self.active.draw then self.active:draw(self.canvas) end
end

return ToolManager
