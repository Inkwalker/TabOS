local width, height = 32, 32
local x, y = 0, 0
local vx, vy = 100, 73
local color = 0x07ff

local function move(position, speed, limit, dt)
    position = position + speed * dt
    if position < 0 then
        return -position, -speed
    elseif position > limit then
        return 2 * limit - position, -speed
    end
    return position, speed
end

-- dt is elapsed time in seconds.
function update(dt)
    if dt > 0.1 then dt = 0.1 end
    local previous_vx, previous_vy = vx, vy
    x, vx = move(x, vx, gfx.width - width, dt)
    y, vy = move(y, vy, gfx.height - height, dt)

    if vx ~= previous_vx or vy ~= previous_vy then
        -- Choose a nonblack color distinct from the current one.
        local next_color = math.random(1, 0xfffe)
        if next_color >= color then next_color = next_color + 1 end
        color = next_color
    end

    gfx.cls()
    gfx.color(color)
    gfx.rectfill(x // 1, y // 1, width, height)
    gfx.flip()
end
