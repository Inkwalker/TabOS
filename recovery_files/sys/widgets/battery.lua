local battery = {}
local level, charging

local defaults = {
    battery_background = gfx.rgb(12, 19, 29),
    battery_track = gfx.rgb(37, 49, 64),
    battery_normal = gfx.rgb(64, 218, 146),
    battery_low = gfx.rgb(255, 183, 62),
    battery_critical = gfx.rgb(255, 92, 97),
    battery_charging = gfx.rgb(108, 205, 255),
}

function battery.refresh()
    local new_level = sys.bat_lvl()
    new_level = new_level and math.min(100, math.max(0, new_level))
    local new_charging = sys.bat_chrg()

    local changed = new_level ~= level or new_charging ~= charging
    level, charging = new_level, new_charging
    return changed, level, charging
end

function battery.draw(x, y, color, colors)
    local body_width, body_height = 16, 7
    colors = colors or defaults

    -- background
    gfx.rectfill(x + 1, y + 1, body_width - 2, body_height - 1,
        colors.battery_background or defaults.battery_background)
    -- outline
    gfx.rect(x, y, body_width - 1, body_height, color)
    -- terminal bump
    gfx.rectfill(x + body_width - 1, y + 2, 1, body_height - 4, color)
    -- track
    gfx.rectfill(x + 2, y + 2, body_width - 5, body_height - 4,
        colors.battery_track or defaults.battery_track)

    if level == nil then
        local middle_y = y + math.floor(body_height / 2)
        gfx.line(x + 2, middle_y, x + body_width - 3, middle_y, color)
    elseif level > 0 then
        local fill_width = math.ceil((body_width - 5) * level / 100)
        local fill
        if charging then
            fill = colors.battery_charging or defaults.battery_charging
        elseif level <= 10 then
            fill = colors.battery_critical or defaults.battery_critical
        elseif level <= 25 then
            fill = colors.battery_low or defaults.battery_low
        else
            fill = colors.battery_normal or defaults.battery_normal
        end
        -- track fill
        gfx.rectfill(x + 2, y + 2, fill_width, body_height - 4, fill)
    end
end

return battery
