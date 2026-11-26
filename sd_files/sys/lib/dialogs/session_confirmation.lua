local Panel = require("lib.ui.panel")
local Label = require("lib.ui.label")
local Button = require("lib.ui.button")
local LauncherTouch = require("lib.launcher_touch")
local SessionConfirmation = {}
SessionConfirmation.__index = SessionConfirmation

function SessionConfirmation.new(app, colors, operation, parent)
    local suspending = operation == "suspend"
    local root = Panel.new({x = 24, y = 26, width = 252, height = 126}, colors.panel, colors.accent)
    root:add(Label.new({x = 8, y = 8, width = 240, height = 8}, app.name, colors.text))
    root:add(Label.new({x = 8, y = 24, width = 240, height = 8},
        suspending and "Suspend app and return to Home?" or "Forget session? Unsaved work is lost.",
        suspending and colors.text or colors.error))
    local style = {color = colors.text, align = "left", padding = 8, pressed_background = colors.pressed}
    root:add(Button.new({x = 8, y = 44, width = 236, height = 22}, suspending and "Suspend App" or "Forget Session",
        {[operation] = app}, style))
    root:add(Button.new({x = 8, y = 92, width = 236, height = 22}, "Cancel", {cancel_menu = true}, style))
    return setmetatable({root = root, parent = parent}, SessionConfirmation)
end

function SessionConfirmation:key_action(input)
    if input.keyp(1, 1) then return {cancel_menu = true} end
end

function SessionConfirmation:poll(input, dt)
    if not self.touch then self.touch = LauncherTouch.new() end
    local action = self:key_action(input)
    if action then
        self.touch:reset(true)
        return action
    end
    return self.touch:update(self.root, input.touch(), dt)
end

function SessionConfirmation:draw()
    return self.root:draw()
end

return SessionConfirmation
