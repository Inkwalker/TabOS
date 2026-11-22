-- Paint callbacks can return a packed history payload alongside their redraw flag.
-- end_drag returns only the payload for the completed gesture.
local ToolManager = {}
ToolManager.__index = ToolManager

function ToolManager.new(canvas, record)
    return setmetatable({canvas = canvas, record = record}, ToolManager)
end

function ToolManager:commit(tool, payload)
    if payload then self.record(tool, payload) end
end

function ToolManager:cancel_drag()
    if not self.contact then return end
    self.contact = nil
    local tool = self.active
    if tool.end_drag then self:commit(tool, tool:end_drag(self.canvas)) end
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
                    local changed, payload = tool:drag(canvas, {
                        x = touch.x - canvas.x, y = touch.y - canvas.y,
                        dx = touch.x - previous.x, dy = touch.y - previous.y,
                    })
                    self:commit(tool, payload)
                    return changed
                end
                return
            end
        end
        self:cancel_drag()
    elseif press and canvas:contains(press.x, press.y) then
        self.contact = press
        if tool.begin_drag then
            local changed, payload = tool:begin_drag(canvas, press.x - canvas.x, press.y - canvas.y)
            self:commit(tool, payload)
            return changed
        end
    end
end

function ToolManager:key_pressed(key)
    local tool = self.active
    if tool and tool.key_pressed then
        local changed, payload = tool:key_pressed(self.canvas, key)
        self:commit(tool, payload)
        return changed
    end
end

function ToolManager:draw()
    if self.active and self.active.draw then self.active:draw(self.canvas) end
end

return ToolManager
