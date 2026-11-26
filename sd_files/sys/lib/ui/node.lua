local Node = {}
Node.__index = Node

-- Rectangles are in parent coordinates. Roots are positioned on screen.
function Node.new(rect)
    return setmetatable({rect = rect, children = {}, visible = true}, Node)
end

function Node:add(child)
    self.children[#self.children + 1] = child
    return child
end

function Node:draw(parent_x, parent_y)
    if not self.visible then return self end
    local x, y = (parent_x or 0) + self.rect.x, (parent_y or 0) + self.rect.y
    if self.draw_self then self:draw_self(x, y) end
    for _, child in ipairs(self.children) do child:draw(x, y) end
    return self
end

function Node:hit_test(touch_x, touch_y, parent_x, parent_y)
    if not self.visible then return end
    local rect = self.rect
    local x, y = (parent_x or 0) + rect.x, (parent_y or 0) + rect.y
    for index = #self.children, 1, -1 do
        local target = self.children[index]:hit_test(touch_x, touch_y, x, y)
        if target then return target end
    end
    if self.hit_target and touch_x >= x and touch_x < x + rect.width
        and touch_y >= y and touch_y < y + rect.height then
        return self:hit_target(x, y)
    end
end

return Node
