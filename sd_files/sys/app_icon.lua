local AppIcon = {size = 16}
local max_source_size = 28 -- Accept icons from older bundles.

function AppIcon.load(path)
    if not path then return end
    local sprite = gfx.load_sprite(path)
    if sprite and (sprite.width > max_source_size or sprite.height > max_source_size) then
        sprite:close()
        return
    end
    return sprite
end

function AppIcon.draw(sprite, x, y, rgb)
    local width, height = sprite.width, sprite.height
    local size = AppIcon.size
    local longest = math.max(width, height)
    local w = math.max(1, width * size // longest)
    local h = math.max(1, height * size // longest)
    local key = rgb and gfx.rgb(rgb[1], rgb[2], rgb[3])
    gfx.sspr(sprite, 0, 0, width, height,
        x + math.floor((size - w) / 2), y + math.floor((size - h) / 2), w, h, key)
end

return AppIcon
