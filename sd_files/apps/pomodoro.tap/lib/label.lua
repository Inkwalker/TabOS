local Label = {}
Label.__index = Label

function Label.new(x, y, text, color)
    return setmetatable({x = x, y = y, text = text, color = color}, Label)
end

function Label:draw()
    gfx.print(self.x, self.y, self.text, self.color)
end

return Label
