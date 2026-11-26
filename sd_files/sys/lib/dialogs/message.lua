local Panel = require("lib.ui.panel")
local Label = require("lib.ui.label")
local Button = require("lib.ui.button")
local Message = {}
Message.__index = Message

function Message.new(text, colors)
    return setmetatable({text = text, colors = colors}, Message)
end

local function layout(self, height)
    local colors = self.colors
    local desktop_width = 300
    local text_width = desktop_width - 32
    local root = Button.new({x = 0, y = 0, width = desktop_width, height = height}, nil, {dismiss = true})
    local panel = root:add(Panel.new({x = 8, y = 28, width = desktop_width - 16, height = height - 60},
        colors.panel, colors.error))
    panel:add(Label.new({x = 8, y = 8, width = text_width, height = 8}, "Shell message", colors.error))
    local text = self.text:gsub("[%c]", " ")
    local width = text_width // 6
    local count = math.max(1, (height - 108) // 10)
    for row = 1, count do
        local start = (row - 1) * width + 1
        local line = text:sub(start, row < count and row * width or -1)
        panel:add(Label.new({x = 8, y = 24 + (row - 1) * 10, width = text_width, height = 8}, line, colors.text))
    end
    panel:add(Label.new({x = 8, y = height - 76, width = text_width, height = 8}, "Tap to dismiss", colors.accent))
    return root
end

function Message:draw()
    if not self.root or self.root.rect.height ~= gfx.height then self.root = layout(self, gfx.height) end
    return self.root:draw()
end

return Message
