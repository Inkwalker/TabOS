local Panel = require("lib.ui.panel")
local Label = require("lib.ui.label")
local Button = require("lib.ui.button")
local AppMenu = {}
AppMenu.__index = AppMenu

function AppMenu.new(app, runner, colors)
    local root = Panel.new({x = 24, y = 26, width = 252, height = 126}, colors.panel, colors.accent)
    root:add(Label.new({x = 8, y = 8, width = 240, height = 8}, app.name, colors.text))
    local status = root:add(Label.new({x = 8, y = 24, width = 240, height = 8}, "", colors.muted))
    local style = {color = colors.text, align = "left", padding = 8, pressed_background = colors.pressed}
    local open = root:add(Button.new({x = 8, y = 44, width = 236, height = 22}, "Open", {app = app}, style))
    local forget = root:add(Button.new({x = 8, y = 68, width = 236, height = 22}, "Forget Session...",
        {confirm_forget = true}, style))
    root:add(Button.new({x = 8, y = 92, width = 236, height = 22}, "Cancel", {cancel_menu = true}, style))
    return setmetatable({app = app, runner = runner, root = root, status = status, open = open, forget = forget}, AppMenu)
end

function AppMenu:draw()
    local suspended = self.runner:has_session(self.app.path)
    self.status.text = suspended and "Suspended" or "Ready"
    self.open:set_text(suspended and "Resume" or "Open")
    self.forget.visible = suspended
    return self.root:draw()
end

return AppMenu
