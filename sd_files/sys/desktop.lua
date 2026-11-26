local ShortcutView = require("lib.shortcut_view")
local Desktop = {}
Desktop.__index = Desktop

local desktop_width = 300

function Desktop.new(apps, config, colors)
    local self = setmetatable({colors = colors}, Desktop)
    local wallpaper_path = config.wallpaper
    if type(wallpaper_path) == "string" and wallpaper_path ~= "" and not wallpaper_path:find("%z") then
        self.wallpaper = gfx.load_sprite(wallpaper_path)
    end
    self:set_shortcuts(apps)
    return self
end

function Desktop:set_shortcuts(apps)
    if self.shortcuts then self.shortcuts:close() end
    self.shortcuts = ShortcutView.new({x = 0, y = 0, width = desktop_width, height = gfx.height}, apps, self.colors)
end

function Desktop:close()
    if self.wallpaper then self.wallpaper:close() end
    self.shortcuts:close()
end

function Desktop:draw(pressed_app)
    gfx.cls(self.colors.background)
    if self.wallpaper then gfx.spr(self.wallpaper, 0, 0) end
    local targets = self.shortcuts:draw(pressed_app)
    targets[#targets + 1] = {x = 0, y = 0, width = desktop_width, height = gfx.height,
        action = {customize_desktop = true}, holdable = true, hold_only = true}
    return targets
end

return Desktop
