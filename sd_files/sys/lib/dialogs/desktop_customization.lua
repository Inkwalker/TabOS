local Panel = require("lib.ui.panel")
local Label = require("lib.ui.label")
local Button = require("lib.ui.button")
local DesktopCustomization = {}
DesktopCustomization.__index = DesktopCustomization

function DesktopCustomization.new(colors)
    local root = Panel.new({x = 24, y = 26, width = 252, height = 102}, colors.panel, colors.accent)
    root:add(Label.new({x = 8, y = 8, width = 236, height = 8}, "Customize Desktop", colors.text))
    local style = {color = colors.text, align = "left", padding = 8, pressed_background = colors.pressed}
    root:add(Button.new({x = 8, y = 30, width = 236, height = 22}, "Add Shortcut", {open_shortcut_picker = true}, style))
    root:add(Button.new({x = 8, y = 64, width = 236, height = 22}, "Cancel", {cancel_menu = true}, style))
    return setmetatable({root = root}, DesktopCustomization)
end

function DesktopCustomization:key_action(input)
    if input.keyp(1, 1) then return {cancel_menu = true} end
end

function DesktopCustomization:draw()
    return self.root:draw()
end

return DesktopCustomization
