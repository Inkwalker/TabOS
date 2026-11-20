local IconButton = require("icon_button")

local ToolPanel = {}
ToolPanel.__index = ToolPanel

local padding, button_size = 4, 20

function ToolPanel.new(bounds, colors, manager, tools)
    local idle_colors = {background = colors.panel}
    local selected_colors = {background = colors.button}
    local buttons = {}
    local x = bounds.x + (bounds.width - button_size) // 2
    for i, tool in ipairs(tools) do
        local y = bounds.y + padding + (i - 1) * (button_size + padding)
        local icon = assert(gfx.load_sprite(os.path(tool.icon_path)))
        local button = IconButton.new(x, y, button_size, button_size,
            icon, idle_colors, function() manager:set_active(tool) end)
        buttons[i] = {tool = tool, button = button, icon = icon}
    end
    return setmetatable({bounds = bounds, background = colors.panel, manager = manager,
        buttons = buttons, idle_colors = idle_colors, selected_colors = selected_colors}, ToolPanel)
end

function ToolPanel:draw()
    local bounds = self.bounds
    gfx.rectfill(bounds.x, bounds.y, bounds.width, bounds.height, self.background)
    for _, entry in ipairs(self.buttons) do
        entry.button.colors = entry.tool == self.manager.active and self.selected_colors or self.idle_colors
        entry.button:draw()
    end
end

function ToolPanel:press(touch)
    for _, entry in ipairs(self.buttons) do
        if entry.button:press(touch) then return true end
    end
    return false
end

function ToolPanel:close()
    for _, entry in ipairs(self.buttons) do entry.icon:close() end
end

return ToolPanel
