local width, height = 32, 32
local x, y = 0, 0
local vx, vy = 100, 73
local color = 0x07ff
local fps_label = " FPS: --"
local presenter_fps_label = "pFPS: --"
local frame_count, frame_time = 0, 0

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
    frame_count = frame_count + 1
    frame_time = frame_time + dt
    if frame_time >= 0.5 then
        fps_label = " FPS: " .. math.floor(frame_count / frame_time + 0.5)
        local presenter_fps = gfx.presenter_fps()
        if presenter_fps > 0 then
            presenter_fps_label = "pFPS: " .. math.floor(presenter_fps + 0.5)
        end
        frame_count, frame_time = 0, 0
    end

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
    gfx.rectfill(math.floor(x), math.floor(y), width, height)
    gfx.color(0xffff)
    gfx.print(1, 1, fps_label)
    gfx.print(1, 10, presenter_fps_label)
    gfx.flip()
end
