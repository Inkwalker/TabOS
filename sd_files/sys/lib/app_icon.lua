local AppIcon = {size = 16}

function AppIcon.load(path)
    if not path then return end
    local sprite = gfx.load_sprite(path)
    if sprite and (sprite.width ~= AppIcon.size or sprite.height ~= AppIcon.size) then
        sprite:close()
        return
    end
    return sprite
end

function AppIcon.draw(sprite, x, y, key)
    gfx.spr(sprite, x, y, key)
end

return AppIcon
