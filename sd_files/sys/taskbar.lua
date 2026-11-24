local AppIcon = require("app_icon")
local Taskbar = {}
Taskbar.__index = Taskbar
Taskbar.HOME = {}
local hold_seconds = 0.6

local function contains(item, contact)
    return contact.x >= 300 and contact.x < 320
        and contact.y >= item.y and contact.y < item.y + 20
end

function Taskbar.new()
    return setmetatable({targets = {}, icons = {}, page = 1, held = true,
        home_icon = assert(gfx.load_sprite("/sd/sys/spr/home.png"))}, Taskbar)
end

local function close_icons(icons)
    for _, sprite in pairs(icons) do
        if sprite then sprite:close() end
    end
end

function Taskbar:clear_icons()
    close_icons(self.icons)
    self.icons = {}
end

function Taskbar:reset()
    self.targets, self.pressed = {}, nil
    self.held, self.owned = true, false
end

-- Keep an entire gesture owned by the system once it starts in the bar.
function Taskbar:route(contacts, dt)
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
                    self.press_elapsed = 0
                    item.id = contacts[1].id
                    break
                end
            end
        end
    elseif self.pressed then
        local item = self.pressed
        if #contacts ~= 1 or contacts[1].id ~= item.id or not contains(item, contacts[1]) then
            self.pressed = nil
        elseif item.app then
            self.press_elapsed = self.press_elapsed + dt
            if self.press_elapsed >= hold_seconds then
                self.pressed = nil
                return nil, item.app
            end
        end
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
    local running, active_index = {}, nil
    local active_key = active and fs.fat_name_key(active.path)
    for _, app in ipairs(apps) do
        if active_key and fs.fat_name_key(app.path) == active_key then
            running[#running + 1] = app
            active_index = #running
        elseif runner:has_session(app.path) then
            running[#running + 1] = app
        end
    end
    local slots = #running > 7 and 6 or 7
    local pages = math.max(1, math.ceil(#running / slots))
    if active_index and active_key ~= self.active_key then
        self.page = math.ceil(active_index / slots)
    end
    self.active_key = active_key
    self.page = math.min(self.page, pages)
    self.targets = {}
    gfx.rectfill(300, 0, 20, 180, colors.panel)
    gfx.line(300, 0, 300, 180, colors.highlight)
    battery.draw(302, 2, colors.text, colors)
    local visible_icons = {}
    local function icon(app, y, is_active)
        local held = self.pressed and self.pressed.app == app
        gfx.rectfill(300, y, 20, 20, (held or is_active) and colors.pressed or colors.tile)
        local sprite
        if app.icon_path then
            sprite = self.icons[app.icon_path]
            self.icons[app.icon_path] = nil
            if sprite == nil then
                sprite = AppIcon.load(app.icon_path) or false
            end
            visible_icons[app.icon_path] = sprite
        end
        if sprite then
            local inset = math.floor((20 - AppIcon.size) / 2)
            AppIcon.draw(sprite, 300 + inset, y + inset, app.icon_key)
        else
            gfx.print(307, y + 6, app.name:sub(1, 1):upper(), colors.accent)
        end
        if is_active then
            gfx.rectfill(300, y, 1, 20, colors.accent)
        else
            self.targets[#self.targets + 1] = {y = y, app = app}
        end
    end
    local first = (self.page - 1) * slots + 1
    for index = first, math.min(#running, first + slots - 1) do
        icon(running[index], 20 + (index - first) * 20, index == active_index)
    end
    close_icons(self.icons)
    self.icons = visible_icons
    if pages > 1 then
        gfx.print(307, 146, ">", colors.text)
        self.targets[#self.targets + 1] = {y = 140, next_page = true, pages = pages}
    end
    gfx.rectfill(301, 161, 18, 18,
        self.pressed and self.pressed.home and colors.pressed or colors.panel)
    gfx.spr(self.home_icon, 302, 162, colors.home_sprite_key)
    self.targets[#self.targets + 1] = {y = 160, home = true}
end

return Taskbar
