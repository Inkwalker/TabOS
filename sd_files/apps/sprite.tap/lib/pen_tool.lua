local PixelCursor = require("pixel_cursor")

local PenTool = {icon_path = "spr/pen.png", history_id = 1, history_version = 1}
PenTool.__index = PenTool

local pixel_record = "<I2I2"
local pixel_record_size = string.packsize(pixel_record)

function PenTool.new(color, cursor_color)
    return setmetatable({color = color, cursor = PixelCursor.new(cursor_color)}, PenTool)
end

function PenTool:reset(canvas, x, y)
    self.stroke, self.touch_x, self.touch_y = nil, nil, nil
    self.cursor:reset(canvas, x, y)
end

function PenTool:activate(canvas)
    self.cursor:activate(canvas)
end

local function cursor_hidden(pen, canvas)
    return pen.touch_x ~= nil and canvas:pixel_at(pen.touch_x, pen.touch_y) == nil
end

function PenTool:draw(canvas)
    if not cursor_hidden(self, canvas) then self.cursor:draw(canvas) end
end

local function paint_line(canvas, x, y, end_x, end_y, color, stroke)
    local left, top, right, bottom = canvas:visible_pixel_bounds()
    local dx, dy = math.abs(end_x - x), -math.abs(end_y - y)
    local step_x, step_y = x < end_x and 1 or -1, y < end_y and 1 or -1
    local error = dx + dy
    local changed = false
    while true do
        if x >= left and x < right and y >= top and y < bottom then
            local painted, before, index = canvas:paint_pixel(x, y, color)
            if painted then
                local mask = (stroke[index] or 0) ~ before ~ color
                stroke[index] = mask ~= 0 and mask or nil
                changed = true
            end
        end
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
    local was_hidden = cursor_hidden(pen, canvas)
    local previous_x, previous_y = canvas:pixel_coordinates(pen.touch_x or x, pen.touch_y or y)
    local px, py = canvas:pixel_coordinates(x, y)
    local changed = paint_line(canvas, previous_x, previous_y, px, py, pen.color, pen.stroke)
    pen.touch_x, pen.touch_y = x, y
    if changed then canvas:render() end
    local cursor_x, cursor_y = canvas:pixel_at(x, y)
    local cursor = pen.cursor
    local moved = cursor_x ~= nil and (cursor.x ~= cursor_x or cursor.y ~= cursor_y)
    if moved then cursor.x, cursor.y = cursor_x, cursor_y end
    return changed or moved or was_hidden ~= (cursor_x == nil)
end

function PenTool:begin_drag(canvas, x, y)
    self.stroke = {}
    return paint_touch(self, canvas, x, y)
end

function PenTool:drag(canvas, motion)
    return paint_touch(self, canvas, motion.x, motion.y)
end

function PenTool:end_drag(canvas)
    local redraw = cursor_hidden(self, canvas)
    local stroke = self.stroke
    self.stroke, self.touch_x, self.touch_y = nil, nil, nil
    if not stroke or not next(stroke) then return redraw end
    local chunks, parts = {}, {}
    for index, mask in pairs(stroke) do
        parts[#parts + 1] = string.pack(pixel_record, index, mask)
        if #parts == 256 then
            chunks[#chunks + 1] = table.concat(parts)
            parts = {}
        end
    end
    chunks[#chunks + 1] = table.concat(parts)
    return redraw, table.concat(chunks)
end

function PenTool:key_pressed(canvas, key)
    if key == "`" then
        local changed, before, index = canvas:paint_pixel(self.cursor.x, self.cursor.y, self.color)
        if not changed then return false end
        canvas:render()
        return true, string.pack(pixel_record, index, before ~ self.color)
    end
    return self.cursor:move(canvas, key)
end

function PenTool.validate_history(version, payload, pixels)
    if version ~= PenTool.history_version or #payload % pixel_record_size ~= 0
        or #payload > pixels * pixel_record_size then
        return false
    end
    for offset = 1, #payload, pixel_record_size do
        local index, mask = string.unpack(pixel_record, payload, offset)
        if index >= pixels or mask == 0 then return false end
    end
    return true
end

function PenTool.apply_history(canvas, _, payload)
    canvas:edit_pixels(function(image)
        local width = image.width
        for offset = 1, #payload, pixel_record_size do
            local index, mask = string.unpack(pixel_record, payload, offset)
            local x, y = index % width, index // width
            gfx.pset(x, y, image:pget(x, y) ~ mask)
        end
    end)
end

return PenTool
