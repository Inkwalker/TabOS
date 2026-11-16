local Taskbar = {}
Taskbar.__index = Taskbar
Taskbar.HOME = {}

local function contains(item, contact)
    return contact.x >= 300 and contact.x < 320
        and contact.y >= item.y and contact.y < item.y + 20
end

function Taskbar.new()
    return setmetatable({targets = {}, page = 1, held = true,
        home_icon = assert(gfx.load_sprite("/sd/sys/spr/home.png"))}, Taskbar)
end

function Taskbar:reset()
    self.targets, self.pressed = {}, nil
    self.held, self.owned = true, false
end

-- Keep an entire gesture owned by the system once it starts in the bar.
function Taskbar:route(contacts)
    if #contacts == 0 then
        local item = self.pressed
        self.held, self.owned, self.pressed = false, false, nil
        if item and item.next_page then
            self.page = self.page % item.pages + 1
        elseif item then
            return item.home and Taskbar.HOME or item.app
        end
        return
    end
    if not self.held then
        self.owned = false
        for _, contact in ipairs(contacts) do
            if contact.x >= 300 then self.owned = true end
        end
        if self.owned and #contacts == 1 then
            for _, item in ipairs(self.targets) do
                if contains(item, contacts[1]) then
                    self.pressed = item
                    item.id = contacts[1].id
                    break
                end
            end
        end
    elseif self.pressed and (#contacts ~= 1 or contacts[1].id ~= self.pressed.id
        or not contains(self.pressed, contacts[1])) then
        self.pressed = nil
    end
    self.held = true
end

function Taskbar:app_touch(contacts)
    if self.owned then return {} end
    local result = {}
    for _, contact in ipairs(contacts) do
        if contact.x < 300 then result[#result + 1] = contact end
    end
    return result
end

function Taskbar:draw(apps, runner, colors, active, battery)
    local suspended = {}
    for _, app in ipairs(apps) do
        if runner:has_session(app.path) then suspended[#suspended + 1] = app end
    end
    local capacity = active and 6 or 7
    local slots = #suspended > capacity and capacity - 1 or capacity
    local pages = math.max(1, math.ceil(#suspended / slots))
    self.page = math.min(self.page, pages)
    self.targets = {}
    gfx.rectfill(300, 0, 20, 180, colors.panel)
    battery.draw(302, 2, colors.text)
    local function icon(app, y, is_active)
        local held = self.pressed and self.pressed.app == app
        gfx.rectfill(300, y, 20, 20, (held or is_active) and colors.pressed or colors.tile)
        if app.icon then
            local scale = math.min(16 / app.icon.width, 16 / app.icon.height)
            local w = math.max(1, math.floor(app.icon.width * scale))
            local h = math.max(1, math.floor(app.icon.height * scale))
            gfx.sspr(app.icon, 0, 0, app.icon.width, app.icon.height,
                300 + math.floor((20 - w) / 2), y + math.floor((20 - h) / 2), w, h)
        else
            gfx.print(307, y + 6, app.name:sub(1, 1):upper(), colors.accent)
        end
        if is_active then
            gfx.rectfill(300, y, 1, 20, colors.accent)
        else
            self.targets[#self.targets + 1] = {y = y, app = app}
        end
    end
    if active then icon(active, 20, true) end
    local first = (self.page - 1) * slots + 1
    local top = active and 40 or 20
    for index = first, math.min(#suspended, first + slots - 1) do
        icon(suspended[index], top + (index - first) * 20)
    end
    if pages > 1 then
        gfx.print(307, 146, ">", colors.text)
        self.targets[#self.targets + 1] = {y = 140, next_page = true, pages = pages}
    end
    gfx.rectfill(300, 160, 20, 20,
        self.pressed and self.pressed.home and colors.pressed or colors.panel)
    gfx.spr(self.home_icon, 302, 162, gfx.rgb(255, 0, 255))
    self.targets[#self.targets + 1] = {y = 160, home = true}
end

return Taskbar
