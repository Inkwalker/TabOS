local PenTool = {icon_path = "spr/pen.png"}
PenTool.__index = PenTool

local arrows = {left = {-1, 0}, right = {1, 0}, up = {0, -1}, down = {0, 1}}

function PenTool.new(color, cursor_color)
    return setmetatable({color = color, cursor_color = cursor_color}, PenTool)
end

function PenTool:reset(canvas, x, y)
    self:end_drag()
    if x ~= nil and y ~= nil then
        self.x, self.y = canvas:clamp_pixel(x, y)
    else
        self.x, self.y = canvas:pixel_at(canvas.width // 2, canvas.height // 2, true)
    end
end

function PenTool:activate(canvas)
    if canvas.image and (self.x == nil or not canvas:pixel_rect(self.x, self.y)) then
        self:reset(canvas)
    end
end

function PenTool:draw(canvas)
    local x, y, width, height = canvas:pixel_rect(self.x, self.y)
    if not x then return end
    local left, top = math.max(canvas.x, x - 1), math.max(canvas.y, y - 1)
    local right = math.min(canvas.x + canvas.width, x + width + 1)
    local bottom = math.min(canvas.y + canvas.height, y + height + 1)
    gfx.rect(left, top, right - left, bottom - top, self.cursor_color)
end

local function paint_line(canvas, x, y, end_x, end_y, color)
    local dx, dy = math.abs(end_x - x), -math.abs(end_y - y)
    local step_x, step_y = x < end_x and 1 or -1, y < end_y and 1 or -1
    local error = dx + dy
    local changed = false
    while true do
        if canvas:paint_pixel(x, y, color) then changed = true end
        if x == end_x and y == end_y then return changed end
        local twice_error = 2 * error
        if twice_error >= dy then
            error, x = error + dy, x + step_x
        end
        if twice_error <= dx then
            error, y = error + dx, y + step_y
        end
    end
end

local function paint_touch(pen, canvas, x, y)
    local px, py = canvas:pixel_at(x, y)
    if not px then
        pen:end_drag()
        return false
    end
    local moved = pen.x ~= px or pen.y ~= py
    local changed = paint_line(canvas, pen.stroke_x or px, pen.stroke_y or py, px, py, pen.color)
    pen.x, pen.y = px, py
    pen.stroke_x, pen.stroke_y = px, py
    if changed then canvas:render() end
    return changed or moved
end

function PenTool:begin_drag(canvas, x, y)
    return paint_touch(self, canvas, x, y)
end

function PenTool:drag(canvas, motion)
    return paint_touch(self, canvas, motion.x, motion.y)
end

function PenTool:end_drag()
    self.stroke_x, self.stroke_y = nil, nil
end

function PenTool:key_pressed(canvas, key)
    if key == "`" then
        if not canvas:paint_pixel(self.x, self.y, self.color) then return false end
        canvas:render()
        return true
    end
    local delta = arrows[key]
    if not delta then return false end
    local x, y = canvas:clamp_pixel(self.x + delta[1], self.y + delta[2])
    if x == self.x and y == self.y then return false end
    self.x, self.y = x, y
    canvas:reveal_pixel(x, y)
    return true
end

return PenTool
