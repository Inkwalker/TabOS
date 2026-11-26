local LauncherTouch = {}
LauncherTouch.__index = LauncherTouch

local hold_seconds = 0.6

local function contains(item, x, y)
    return x >= item.x and x < item.x + item.width and y >= item.y and y < item.y + item.height
end

local function hit_test(surface, x, y)
    if surface.hit_test then return surface:hit_test(x, y) end
    for _, item in ipairs(surface) do
        if contains(item, x, y) then return item end
    end
end

function LauncherTouch.new()
    return setmetatable({held = true}, LauncherTouch)
end

function LauncherTouch:reset(held)
    local item = self.pressed
    if item and item.node then item.node:set_pressed(false) end
    self.held, self.pressed = held, nil
end

function LauncherTouch:update(surface, contacts, dt)
    if #contacts == 0 then
        local item = self.pressed
        self:reset(false)
        if item then
            if item.node then
                local target = hit_test(surface, self.last_x, self.last_y)
                if not target or target.node ~= item.node or target.action ~= item.action then return nil, true end
            end
            return item.action, true
        end
        return
    end

    local contact = contacts[1]
    local dirty
    if not self.held and #contacts == 1 then
        local item = hit_test(surface, contact.x, contact.y)
        if item then
            self.pressed, self.contact_id, self.elapsed = item, contact.id, 0
            if item.node then item.node:set_pressed(true) end
            dirty = true
        end
    elseif self.pressed and (#contacts ~= 1 or contact.id ~= self.contact_id
        or not contains(self.pressed, contact.x, contact.y)) then
        self:reset(true)
        dirty = true
    end
    self.held = true

    local item = self.pressed
    if item and item.node then self.last_x, self.last_y = contact.x, contact.y end
    if item and item.holdable then
        self.elapsed = self.elapsed + dt
        if self.elapsed >= hold_seconds then
            self:reset(true)
            return item.action, true, true
        end
    end
    return nil, dirty
end

return LauncherTouch
