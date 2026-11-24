local AppIcon = require("app_icon")
local Desktop = {}
Desktop.__index = Desktop

local desktop_width = 300
local cell_size = 45
local columns = desktop_width // cell_size
local rows = gfx.height // cell_size
local desktop_slots = columns * rows
local icon_backing_inset = (20 - AppIcon.size) // 2
local icon_backing_key = gfx.rgb(255, 0, 255)

local function shortened(text, limit)
    if #text <= limit then return text end
    return text:sub(1, math.max(0, limit - 3)) .. "..."
end

local function centered(x, y, width, text, color)
    gfx.print(x + math.floor((width - #text * 6) / 2), y, text, color)
end

local function contains(item, x, y)
    return x >= item.x and x < item.x + item.width
        and y >= item.y and y < item.y + item.height
end

function Desktop.new(apps, config, colors, runner)
    local self = setmetatable({
        apps = apps, colors = colors, runner = runner,
        targets = {}, icons = {}, touch_held = true,
    }, Desktop)
    local wallpaper_path = config.wallpaper
    if type(wallpaper_path) == "string" and wallpaper_path ~= "" and not wallpaper_path:find("%z") then
        self.wallpaper = gfx.load_sprite(wallpaper_path)
    end
    for index = 1, math.min(#apps, desktop_slots) do
        self.icons[index] = AppIcon.load(apps[index].icon_path)
    end
    self.icon_backing = gfx.load_sprite("/sd/sys/spr/icon_backing.png")
    return self
end

function Desktop:close()
    if self.wallpaper then self.wallpaper:close() end
    if self.icon_backing then self.icon_backing:close() end
    for _, icon in pairs(self.icons) do icon:close() end
end

function Desktop:reset_contact(held)
    self.touch_held, self.pressed = held, nil
end

function Desktop:close_menu()
    self.app_menu, self.confirm_forget = nil, false
end

function Desktop:draw(chooser, message)
    local apps, icons, colors = self.apps, self.icons, self.colors
    local pressed, app_menu = self.pressed, self.app_menu
    local targets = {}
    local function target(x, y, width, height, action)
        targets[#targets + 1] = {x = x, y = y, width = width, height = height, action = action}
    end
    gfx.cls(colors.background)
    if self.wallpaper then gfx.spr(self.wallpaper, 0, 0) end
    for index = 1, math.min(#apps, desktop_slots) do
        local app = apps[index]
        local slot = index - 1
        local x = (slot // rows) * cell_size
        local y = (slot % rows) * cell_size
        target(x, y, cell_size, cell_size, {app = app})
        local held = pressed and pressed.action.app == app
        if held then gfx.rectfill(x + 2, y + 2, cell_size - 4, cell_size - 4, colors.pressed) end
        local icon_size = AppIcon.size
        local icon_x = x + (cell_size - icon_size) // 2
        local icon_y = y + 9
        if self.icon_backing then
            gfx.spr(self.icon_backing, icon_x - icon_backing_inset, icon_y - icon_backing_inset,
                icon_backing_key)
        end
        local icon = icons[index]
        if icon then
            AppIcon.draw(icon, icon_x, icon_y, app.icon_key)
        else
            centered(icon_x, icon_y + 4, icon_size, app.name:sub(1, 1):upper(), colors.text)
        end
        local label = shortened(app.name, cell_size // 6)
        centered(x, y + 29, cell_size, label, colors.text)
    end
    if #apps == 0 then
        centered(0, 74, desktop_width, "No desktop shortcuts", colors.muted)
        centered(0, 88, desktop_width, "Add apps to /sd/sys/shortcuts.ltab", colors.muted)
    end

    if app_menu then
        targets = {}
        local suspended = self.runner:has_session(app_menu.path)
        gfx.rectfill(24, 26, desktop_width - 48, 126, colors.panel)
        gfx.rect(24, 26, desktop_width - 48, 126, colors.accent)
        gfx.print(32, 34, shortened(app_menu.name, 40), colors.text)
        local function menu_button(y, label, action)
            target(32, y, desktop_width - 64, 22, action)
            gfx.print(40, y + 6, label, colors.text)
        end
        if self.confirm_forget then
            gfx.print(32, 50, "Forget session? Unsaved work is lost.", colors.error)
            menu_button(70, "Forget Session", {forget = app_menu})
            menu_button(118, "Cancel", {cancel_menu = true})
        else
            gfx.print(32, 50, suspended and "Suspended" or "Ready", colors.muted)
            menu_button(70, suspended and "Resume" or "Open", {app = app_menu})
            if suspended then menu_button(94, "Forget Session...", {confirm_forget = true}) end
            menu_button(118, "Cancel", {cancel_menu = true})
        end
    end
    if chooser then
        targets = {}
        gfx.rectfill(8, 8, 284, 164, colors.panel)
        gfx.rect(8, 8, 284, 164, colors.accent)
        gfx.print(16, 16, "Open With", colors.text)
        local name = chooser.path:match("[^/]+$")
        gfx.print(16, 29, shortened(name, 44), colors.muted)
        local first = math.floor((chooser.selected - 1) / 4) * 4 + 1
        for index = first, math.min(first + 3, #chooser.candidates) do
            local y = 42 + (index - first) * 20
            local app = chooser.candidates[index]
            target(16, y, 268, 20, {candidate = index})
            if index == chooser.selected then gfx.rectfill(16, y, 268, 20, colors.pressed) end
            gfx.print(22, y + 6, shortened(app.name, 27), colors.text)
            gfx.print(191, y + 6, shortened(app.path:match("[^/]+$"), 15), colors.muted)
        end
        local function choice(x, y, w, label, action)
            target(x, y, w, 22, action)
            centered(x, y + 7, w, label, colors.accent)
        end
        if first > 1 then choice(16, 122, 46, "Prev", {candidate = first - 4}) end
        if first + 4 <= #chooser.candidates then
            choice(238, 122, 46, "Next", {candidate = first + 4})
        end
        centered(62, 129, 176, chooser.selected .. "/" .. #chooser.candidates, colors.muted)
        choice(16, 144, 90, "Just Once", {open_choice = "once"})
        choice(106, 144, 88, "Always", {open_choice = "always"})
        choice(194, 144, 90, "Cancel", {cancel_chooser = true})
    end
    if message then
        targets = {}
        target(0, 0, desktop_width, gfx.height, {dismiss = true})
        gfx.rectfill(8, 28, desktop_width - 16, gfx.height - 60, colors.panel)
        gfx.rect(8, 28, desktop_width - 16, gfx.height - 60, colors.error)
        gfx.print(16, 36, "Shell message", colors.error)
        local text = message:gsub("[%c]", " ")
        local width = math.max(1, math.floor((desktop_width - 32) / 6))
        local count = math.max(1, math.floor((gfx.height - 108) / 10))
        for row = 1, count do
            local line = text:sub((row - 1) * width + 1, row * width)
            if row == count and #text > row * width then
                line = shortened(text:sub((row - 1) * width + 1), width)
            end
            gfx.print(16, 52 + (row - 1) * 10, line, colors.text)
        end
        gfx.print(16, gfx.height - 48, "Tap to dismiss", colors.accent)
    end
    self.targets = targets
end

function Desktop:update_touch(contacts, dt)
    if #contacts == 0 then
        local action = self.pressed and self.pressed.action
        self:reset_contact(false)
        if action then
            if action.confirm_forget then
                self.confirm_forget = true
            elseif action.cancel_menu then
                self:close_menu()
            else
                return action, true
            end
            return nil, true
        end
        return
    end

    local contact = contacts[1]
    local dirty
    if not self.touch_held and #contacts == 1 then
        for _, item in ipairs(self.targets) do
            if contains(item, contact.x, contact.y) then
                self.pressed = item
                item.id = contact.id
                self.press_elapsed = 0
                dirty = true
                break
            end
        end
    elseif self.pressed and (#contacts ~= 1 or contact.id ~= self.pressed.id
        or not contains(self.pressed, contact.x, contact.y)) then
        self.pressed = nil
        dirty = true
    end
    if self.pressed and self.pressed.action.app and not self.app_menu then
        self.press_elapsed = self.press_elapsed + dt
        if self.press_elapsed >= 0.6 then
            self.app_menu = self.pressed.action.app
            self.confirm_forget, self.pressed = false, nil
            dirty = true
        end
    end
    self.touch_held = true
    return nil, dirty
end

return Desktop
