local AppIcon = require("lib.app_icon")
local ShortcutView = {}
ShortcutView.__index = ShortcutView

local cell_size = 45
local icon_backing_inset = (20 - AppIcon.size) // 2
local icon_backing_key = gfx.rgb(255, 0, 255)

local function shortened(text, limit)
    if #text <= limit then return text end
    return text:sub(1, limit - 3) .. "..."
end

local function centered(x, y, width, text, color)
    gfx.print(x + (width - #text * 6) // 2, y, text, color)
end

function ShortcutView.new(rect, apps, colors)
    local rows = rect.height // cell_size
    local capacity = (rect.width // cell_size) * rows
    local count = math.min(#apps, capacity)
    local icons = {}
    for index = 1, count do
        icons[index] = AppIcon.load(apps[index].icon_path)
    end
    return setmetatable({
        rect = rect, apps = apps, colors = colors, rows = rows, count = count, capacity = capacity,
        icons = icons, icon_backing = gfx.load_sprite("/sd/sys/spr/icon_backing.png"),
    }, ShortcutView)
end

function ShortcutView:close()
    if self.icon_backing then self.icon_backing:close() end
    for _, icon in pairs(self.icons) do icon:close() end
end

function ShortcutView:draw(pressed_app)
    local rect, apps, colors = self.rect, self.apps, self.colors
    local targets = {}
    for index = 1, self.count do
        local app = apps[index]
        local slot = index - 1
        local x = rect.x + (slot // self.rows) * cell_size
        local y = rect.y + (slot % self.rows) * cell_size
        targets[index] = {x = x, y = y, width = cell_size, height = cell_size,
            action = {app = app}, holdable = true}
        if pressed_app == app then
            gfx.rectfill(x + 2, y + 2, cell_size - 4, cell_size - 4, colors.pressed)
        end
        local icon_size = AppIcon.size
        local icon_x = x + (cell_size - icon_size) // 2
        local icon_y = y + 9
        if self.icon_backing then
            gfx.spr(self.icon_backing, icon_x - icon_backing_inset, icon_y - icon_backing_inset,
                icon_backing_key)
        end
        local icon = self.icons[index]
        if icon then
            AppIcon.draw(icon, icon_x, icon_y, app.icon_key)
        else
            centered(icon_x, icon_y + 4, icon_size, app.name:sub(1, 1):upper(), colors.text)
        end
        centered(x, y + 29, cell_size, shortened(app.name, cell_size // 6), colors.text)
    end
    if #apps == 0 and rect.width >= 18 and rect.height >= 32 then
        local y = rect.y + rect.height // 2 - 16
        local limit = rect.width // 6
        centered(rect.x, y, rect.width, shortened("No desktop shortcuts", limit), colors.muted)
        centered(rect.x, y + 14, rect.width, shortened("Hold empty space to add a shortcut", limit), colors.muted)
    end
    return targets
end

return ShortcutView
