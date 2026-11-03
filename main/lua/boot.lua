local width, height = 32, 32
local rectangles = {}
local max_x, max_y = gfx.width - width, gfx.height - height
local fps_label = " FPS: --"
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

function init()
    gfx.print(1, 1, "Initializing...")
    for i = 1, 100 do
        rectangles[i] = {
            x = math.random(0, max_x),
            y = math.random(0, max_y),
            vx = math.random(60, 140) * (2 * math.random(0, 1) - 1),
            vy = math.random(60, 140) * (2 * math.random(0, 1) - 1),
            color = math.random(1, 0xffff),
        }
    end
end

-- dt is elapsed time in seconds.
function update(dt)
    frame_count = frame_count + 1
    frame_time = frame_time + dt
    if frame_time >= 0.5 then
        local presenter_fps = gfx.presenter_fps()
        fps_label = " FPS: " .. math.floor(frame_count / frame_time + 0.5) .. " (" .. math.floor(presenter_fps + 0.5) .. ")"
        frame_count, frame_time = 0, 0
    end

    if dt > 0.01 then dt = 0.01 end
    gfx.cls()
    for i = 1, #rectangles do
        local rect = rectangles[i]
        local previous_vx, previous_vy = rect.vx, rect.vy
        rect.x, rect.vx = move(rect.x, rect.vx, max_x, dt)
        rect.y, rect.vy = move(rect.y, rect.vy, max_y, dt)

        if rect.vx ~= previous_vx or rect.vy ~= previous_vy then
            -- Choose a nonblack color distinct from the current one.
            local next_color = math.random(1, 0xfffe)
            if next_color >= rect.color then next_color = next_color + 1 end
            rect.color = next_color
        end

        gfx.color(rect.color)
        gfx.rectfill(math.floor(rect.x), math.floor(rect.y), width, height)
    end
    gfx.color(0xffff)
    gfx.print(1, 1, fps_label)
    gfx.flip()
end
