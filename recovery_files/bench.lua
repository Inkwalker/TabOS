local width, height = 32, 32
local rectangles = {}
local max_x, max_y = gfx.width - width, gfx.height - height
local fps_label = "FPS: --"
local frame_count, frame_time = 0, 0
local sram_label = "SRAM: --"
local psram_label = "PSRAM: --"
local cpu_label = "CPU0: --  CPU1: --"
local glyph_width = 6 -- Default gfx.print font at size 1.
local count_y = gfx.height - 9
local attraction_radius = 80
local attraction_strength = 2

local function move(position, speed, limit, dt)
    position = position + speed * dt
    if position < 0 then
        return -position, -speed
    elseif position > limit then
        return 2 * limit - position, -speed
    end
    return position, speed
end

local function steer_toward_touches(rect, touches, dt)
    for _, touch in ipairs(touches) do
        local dx = touch.x - (rect.x + width / 2)
        local dy = touch.y - (rect.y + height / 2)
        local distance_squared = dx * dx + dy * dy
        if distance_squared > 0 and distance_squared < attraction_radius * attraction_radius then
            local distance = math.sqrt(distance_squared)
            local speed = math.sqrt(rect.vx * rect.vx + rect.vy * rect.vy)
            local pull = attraction_strength * dt * (1 - distance / attraction_radius)
            local vx = rect.vx + dx / distance * speed * pull
            local vy = rect.vy + dy / distance * speed * pull
            local scale = speed / math.sqrt(vx * vx + vy * vy)
            rect.vx, rect.vy = vx * scale, vy * scale
        end
    end
end

local function set_square_count(count)
    count = math.max(1, count)
    for i = #rectangles, count + 1, -1 do
        rectangles[i] = nil
    end
    for i = #rectangles + 1, count do
        rectangles[i] = {
            x = math.random(0, max_x),
            y = math.random(0, max_y),
            vx = math.random(60, 140) * (2 * math.random(0, 1) - 1),
            vy = math.random(60, 140) * (2 * math.random(0, 1) - 1),
            color = math.random(1, 0xffff),
        }
    end
end

function init()
    gfx.print(1, 1, "Initializing...")
    sys.cpu_load()
    set_square_count(100)
end

-- dt is elapsed time in seconds.
function update(dt)
    input.update()
    for key in input.txt():gmatch("[+%-]") do
        set_square_count(#rectangles + (key == "+" and 50 or -50))
    end

    frame_count = frame_count + 1
    frame_time = frame_time + dt
    if frame_time >= 0.5 then
        local presenter_fps = gfx.presenter_fps()
        fps_label = "FPS: " .. math.floor(frame_count / frame_time + 0.5) .. " (" .. math.floor(presenter_fps + 0.5) .. ")"
        frame_count, frame_time = 0, 0

        local sram_used, sram_total   = sys.sram()
        local psram_used, psram_total = sys.psram()
        sram_label = "SRAM: " .. sram_used // 1000 .. "K / " .. sram_total // 1000 .. "K"
        psram_label = "PSRAM: " .. psram_used // 1000 .. "K / " .. psram_total // 1000 .. "K"

        local core0, core1 = sys.cpu_load()
        if core0 ~= nil then
            cpu_label = string.format("CPU0: %.0f%%  CPU1: %.0f%%", core0, core1)
        end
    end

    if dt > 0.01 then dt = 0.01 end
    local touches = input.touch()
    gfx.cls()
    for i = 1, #rectangles do
        local rect = rectangles[i]
        if #touches > 0 then
            steer_toward_touches(rect, touches, dt)
        end
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

    local cpu_x = gfx.width - #cpu_label * glyph_width - 1
    gfx.color(0x0000)
    gfx.print(2, 2, fps_label)
    gfx.print(cpu_x + 1, 2, cpu_label)

    gfx.color(0xffff)
    gfx.print(1, 1, fps_label)
    gfx.print(cpu_x, 1, cpu_label)
    gfx.print(1, 160, sram_label)
    gfx.print(1, 170, psram_label)
    for i = 1, #touches do
        local touch = touches[i]
        gfx.circ(touch.x, touch.y, 16, 0xffff)
    end

    local count_label = "Squares: " .. #rectangles
    local count_width = #count_label * glyph_width
    local count_x = gfx.width - count_width - 1
    gfx.rectfill(count_x - 1, count_y - 1, count_width + 2, 10, 0x0000)
    gfx.print(count_x, count_y, count_label, 0xffff)
    gfx.flip()
end
