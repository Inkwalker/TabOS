local SpriteCanvas = {}
SpriteCanvas.__index = SpriteCanvas

SpriteCanvas.max_pixels = 65536
local max_zoom = math.maxinteger // SpriteCanvas.max_pixels

function SpriteCanvas.new(x, y, width, height, background)
    return setmetatable({x = x, y = y, width = width, height = height, background = background}, SpriteCanvas)
end

function SpriteCanvas:contains(x, y)
    return x >= self.x and x < self.x + self.width and y >= self.y and y < self.y + self.height
end

local function clamp_pan(size, extent, scale, pan)
    local span = size * scale
    local center = (extent - span) // 2
    -- Keep at least one pixel visible so the sprite can always be dragged back.
    return math.max(1 - span, math.min(extent - 1, center + pan)) - center
end

local function set_pan(canvas, x, y)
    canvas.pan_x = clamp_pan(canvas.image.width, canvas.width, canvas.zoom, x)
    canvas.pan_y = clamp_pan(canvas.image.height, canvas.height, canvas.zoom, y)
end

local function sprite_offset(size, extent, scale, pan)
    return (extent - size * scale) // 2 + pan
end

local function sprite_origin(canvas)
    return sprite_offset(canvas.image.width, canvas.width, canvas.zoom, canvas.pan_x),
        sprite_offset(canvas.image.height, canvas.height, canvas.zoom, canvas.pan_y)
end

function SpriteCanvas:clamp_pixel(x, y)
    return math.max(0, math.min(self.image.width - 1, x)), math.max(0, math.min(self.image.height - 1, y))
end

function SpriteCanvas:pixel_coordinates(x, y)
    local left, top = sprite_origin(self)
    return (x - left) // self.zoom, (y - top) // self.zoom
end

function SpriteCanvas:pixel_at(x, y, nearest)
    if not self.image or not self:contains(self.x + x, self.y + y) then return end
    local px, py = self:pixel_coordinates(x, y)
    local clamped_x, clamped_y = self:clamp_pixel(px, py)
    if nearest or (px == clamped_x and py == clamped_y) then return clamped_x, clamped_y end
end

function SpriteCanvas:pixel_rect(x, y)
    local left, top = sprite_origin(self)
    left, top = left + x * self.zoom, top + y * self.zoom
    local right, bottom = math.min(self.width, left + self.zoom), math.min(self.height, top + self.zoom)
    left, top = math.max(0, left), math.max(0, top)
    if right > left and bottom > top then
        return self.x + left, self.y + top, right - left, bottom - top
    end
end

local function reveal_offset(start, size, extent)
    local visible = math.min(size, extent)
    if start < 0 then return math.max(0, visible - start - size) end
    return math.min(0, extent - start - visible)
end

function SpriteCanvas:reveal_pixel(x, y)
    local left, top = sprite_origin(self)
    return self:pan_by(reveal_offset(left + x * self.zoom, self.zoom, self.width),
        reveal_offset(top + y * self.zoom, self.zoom, self.height))
end

local function visible_span(size, extent, scale, pan)
    local offset = sprite_offset(size, extent, scale, pan)
    local first = math.max(0, -offset // scale)
    local last = math.min(size - 1, (extent - 1 - offset) // scale)
    return first, last - first + 1, offset + first * scale
end

function SpriteCanvas:visible_pixel_bounds()
    local x, width = visible_span(self.image.width, self.width, self.zoom, self.pan_x)
    local y, height = visible_span(self.image.height, self.height, self.zoom, self.pan_y)
    return x, y, x + width, y + height
end

local function edit_image(image, paint)
    gfx.target(image.width, image.height)
    gfx.spr(image, 0, 0)
    paint(image)
    gfx.flip(image)
end

local function commit_edits(canvas)
    local pending = canvas.pending_edits
    if not next(pending) then return end

    edit_image(canvas.image, function(image)
        local width = image.width
        for index, color in pairs(pending) do
            gfx.pset(index % width, index // width, color)
        end
    end)
    canvas.pending_edits = {}
end

local function render(canvas, paint)
    local scale = canvas.zoom
    local image = canvas.image
    local sx, sw, dx = visible_span(image.width, canvas.width, scale, canvas.pan_x)
    local sy, sh, dy = visible_span(image.height, canvas.height, scale, canvas.pan_y)

    -- Capture the sprite pass before restoring the shared window canvas.
    local window_width, window_height = gfx.width, gfx.height
    commit_edits(canvas)
    if paint then edit_image(image, paint) end
    gfx.target(canvas.width, canvas.height)
    gfx.cls(canvas.background)
    if sw * scale <= 32767 and sh * scale <= 32767 then
        gfx.sspr(image, sx, sy, sw, sh, dx, dy, sw * scale, sh * scale)
    else
        -- The viewport crosses at most two texels per axis at these scales.
        for row = 0, sh - 1 do
            local y = dy + row * scale
            local top = math.max(0, y)
            local h = math.min(canvas.height, y + scale) - top
            for col = 0, sw - 1 do
                local x = dx + col * scale
                local left = math.max(0, x)
                local w = math.min(canvas.width, x + scale) - left
                gfx.rectfill(left, top, w, h, image:pget(sx + col, sy + row))
            end
        end
    end
    gfx.flip(canvas.preview)
    gfx.target(window_width, window_height)
end

function SpriteCanvas:render()
    render(self)
end

function SpriteCanvas:flush_edits()
    if not next(self.pending_edits) then return false end
    self:render()
    return true
end

-- The callback draws into the sprite-sized target and can read its original pixels from image.
function SpriteCanvas:edit_pixels(paint)
    render(self, paint)
end

function SpriteCanvas:set_sprite(image, zoom, pan_x, pan_y)
    if image.width * image.height > SpriteCanvas.max_pixels then
        return nil, "PNG exceeds the 65,536-pixel canvas limit"
    end
    if not self.preview then
        local preview, err = gfx.create_sprite(self.width, self.height)
        if not preview then return nil, err end
        self.preview = preview
    end
    self.image = image
    self.zoom = zoom or 1
    self.pending_edits = {}
    set_pan(self, pan_x or 0, pan_y or 0)
    self:render()
    return true
end

function SpriteCanvas:pixel_color(x, y)
    return self.pending_edits[y * self.image.width + x] or self.image:pget(x, y)
end

function SpriteCanvas:paint_pixel(x, y, color)
    if x < 0 or x >= self.image.width or y < 0 or y >= self.image.height then return false end
    local before = self:pixel_color(x, y)
    if before == color then return false end
    local index = y * self.image.width + x
    self.pending_edits[index] = color
    return true, before, index
end

function SpriteCanvas:zoom_by(step)
    -- Keep scaled sprite dimensions within Lua's integer range.
    if step > 0 and self.zoom > max_zoom // 2 then return false end
    local zoom = step > 0 and self.zoom * 2 or math.max(1, self.zoom // 2)
    if zoom == self.zoom then return false end
    local ratio = zoom / self.zoom
    self.zoom = zoom
    set_pan(self, math.floor(self.pan_x * ratio + 0.5), math.floor(self.pan_y * ratio + 0.5))
    self:render()
    return true
end

function SpriteCanvas:pan_by(dx, dy)
    if not self.image then return false end
    local x, y = self.pan_x, self.pan_y
    set_pan(self, x + dx, y + dy)
    if x == self.pan_x and y == self.pan_y then return false end
    self:render()
    return true
end

function SpriteCanvas:draw()
    if self.preview then
        gfx.spr(self.preview, self.x, self.y)
    else
        gfx.rectfill(self.x, self.y, self.width, self.height, self.background)
    end
end

function SpriteCanvas:close()
    if self.preview then
        self.preview:close()
        self.preview = nil
    end
    self.image = nil
end

return SpriteCanvas
