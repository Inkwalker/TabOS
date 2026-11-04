local width, height = 32, 32
local rectangles = {}
local max_x, max_y = gfx.width - width, gfx.height - height
local fps_label = "FPS: --"
local frame_count, frame_time = 0, 0
local sram_label = "SRAM: --"
local psram_label = "PSRAM: --"
local battery_level, battery_charging
local battery_colors = {
    background = gfx.rgb(12, 19, 29),
    track = gfx.rgb(37, 49, 64),
    outline = gfx.rgb(198, 214, 231),
    normal = gfx.rgb(64, 218, 146),
    low = gfx.rgb(255, 183, 62),
    critical = gfx.rgb(255, 92, 97),
    charging = gfx.rgb(108, 205, 255),
}

local function draw_battery()
    local x, y = gfx.width - 17, 1
    local body_width, body_height = 16, 8
    local colors = battery_colors

    gfx.rectfill(x + 1, y + 1, body_width - 1, body_height - 1, colors.background)
    gfx.rect(x, y, body_width, body_height, colors.outline)
    gfx.rectfill(x - 1, y + 2, 1, 4, colors.outline)
    gfx.rectfill(x + 2, y + 2, body_width - 4, body_height - 4, colors.track)

    if battery_level == nil then
        gfx.line(x + 2, y + 4, x + body_width - 2, y + 4, colors.outline)
    elseif battery_level > 0 then
        local fill_width = math.ceil((body_width - 4) * battery_level / 100)
        local fill = colors.normal
        if battery_level <= 10 then
            fill = colors.critical
        elseif battery_level <= 25 then
            fill = colors.low
        end
        if battery_charging then 
            fill = colors.charging 
        end
        gfx.rectfill(x + 2, y + 2, fill_width, body_height - 4, fill)
    end
end

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

    sys.set_led(1, 0, 0, 255)
    sys.set_led(2, 0, 0, 0)
    sys.set_led_brightness(10)

    for i = 1, 100 do
        rectangles[i] = {
            x = math.random(0, max_x),
            y = math.random(0, max_y),
            vx = math.random(60, 140) * (2 * math.random(0, 1) - 1),
            vy = math.random(60, 140) * (2 * math.random(0, 1) - 1),
            color = math.random(1, 0xffff),
        }
    end

    sys.set_led(1, 255, 128, 40)
end

-- dt is elapsed time in seconds.
function update(dt)
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

        local level = sys.bat_lvl()
        battery_level = level and math.min(100, math.max(0, level))
        battery_charging = sys.bat_chrg()
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

    gfx.color(0x0000)
    gfx.print(2, 2, fps_label)

    gfx.color(0xffff)
    gfx.print(1, 1, fps_label)
    gfx.print(1, 160, sram_label)
    gfx.print(1, 170, psram_label)
    draw_battery()
    gfx.flip()
end
