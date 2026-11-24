local PixelCursor = {}
PixelCursor.__index = PixelCursor

local arrows = {left = {-1, 0}, right = {1, 0}, up = {0, -1}, down = {0, 1}}

function PixelCursor.new(color)
    return setmetatable({color = color}, PixelCursor)
end

function PixelCursor:reset(canvas, x, y)
    if x ~= nil and y ~= nil then
        self.x, self.y = canvas:clamp_pixel(x, y)
    else
        self.x, self.y = canvas:pixel_at(canvas.width // 2, canvas.height // 2, true)
    end
end

function PixelCursor:activate(canvas)
    if canvas.image and (self.x == nil or not canvas:pixel_rect(self.x, self.y)) then
        self:reset(canvas)
    end
end

function PixelCursor:draw(canvas)
    local x, y, width, height = canvas:pixel_rect(self.x, self.y)
    if not x then return end
    local left, top = math.max(canvas.x, x - 1), math.max(canvas.y, y - 1)
    local right = math.min(canvas.x + canvas.width, x + width + 1)
    local bottom = math.min(canvas.y + canvas.height, y + height + 1)
    gfx.rect(left, top, right - left, bottom - top, self.color)
end

function PixelCursor:move(canvas, key)
    local delta = arrows[key]
    if not delta then return false end
    local x = (self.x + delta[1]) % canvas.image.width
    local y = (self.y + delta[2]) % canvas.image.height
    if x == self.x and y == self.y then return false end
    self.x, self.y = x, y
    canvas:reveal_pixel(x, y)
    return true
end

return PixelCursor
