local palette_width, palette_height = 64, 128
local padding_x, padding_y = 6, 4

local ColorPicker = {width = palette_width + 2 * padding_x}
ColorPicker.__index = ColorPicker

function ColorPicker.new(x, y, height, background, color, palette_path)
    local palette = assert(gfx.load_sprite(palette_path))
    if palette.width ~= palette_width or palette.height ~= palette_height then
        palette:close()
        error("Expected a 64 x 128 palette PNG: " .. palette_path, 0)
    end
    return setmetatable({x = x, y = y, height = height, background = background, color = color,
        palette = palette, palette_path = palette_path, palette_x = x + padding_x, palette_y = y + padding_y}, ColorPicker)
end

function ColorPicker:select(x, y)
    self.selected_x, self.selected_y = x, y
    self.color = self.palette:pget(x, y)
    return self.color
end

function ColorPicker:restore(saved)
    if saved and saved.path == self.palette_path then
        return self:select(saved.x, saved.y)
    end
    return self.color
end

function ColorPicker:save_state()
    if self.selected_x then
        return {path = self.palette_path, x = self.selected_x, y = self.selected_y}
    end
end

function ColorPicker:draw()
    local x, y = self.palette_x, self.palette_y
    gfx.rectfill(self.x, self.y, self.width, self.height, self.background)
    gfx.spr(self.palette, x, y)

    if self.selected_x then
        local marker_x, marker_y = x + self.selected_x, y + self.selected_y
        gfx.rect(marker_x - 3, marker_y - 3, 7, 7, 0x0000)
        gfx.rect(marker_x - 2, marker_y - 2, 5, 5, 0xffff)
    end

    local swatch_y = y + palette_height + 3
    gfx.rect(x, swatch_y, palette_width, 4, 0xffff)
    gfx.rectfill(x + 1, swatch_y + 1, palette_width - 2, 2, self.color)
end

function ColorPicker:update_touch(touch, press)
    if press then
        local x, y = press.x - self.palette_x, press.y - self.palette_y
        if x >= 0 and x < palette_width and y >= 0 and y < palette_height then
            self.contact = press.id
        end
    end
    if not touch or touch.id ~= self.contact then
        self.contact = nil
        return
    end

    local x = math.max(0, math.min(palette_width - 1, touch.x - self.palette_x))
    local y = math.max(0, math.min(palette_height - 1, touch.y - self.palette_y))
    if x ~= self.selected_x or y ~= self.selected_y then
        return self:select(x, y)
    end
end

function ColorPicker:close()
    self.palette:close()
end

return ColorPicker
