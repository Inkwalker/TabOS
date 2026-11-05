local battery = {}
local level, charging

local colors = {
    background = gfx.rgb(12, 19, 29),
    track = gfx.rgb(37, 49, 64),
    normal = gfx.rgb(64, 218, 146),
    low = gfx.rgb(255, 183, 62),
    critical = gfx.rgb(255, 92, 97),
    charging = gfx.rgb(108, 205, 255),
}

function battery.refresh()
    local new_level = sys.bat_lvl()
    new_level = new_level and math.min(100, math.max(0, new_level))
    local new_charging = sys.bat_chrg()

    local changed = new_level ~= level or new_charging ~= charging
    level, charging = new_level, new_charging
    return changed
end

function battery.draw(x, y, color)
    local body_width, body_height = 16, 8

    gfx.rectfill(x + 1, y + 1, body_width - 1, body_height - 1, colors.background)
    gfx.rect(x, y, body_width, body_height, color)
    gfx.rectfill(x - 1, y + 2, 1, 4, color)
    gfx.rectfill(x + 2, y + 2, body_width - 4, body_height - 4, colors.track)

    if level == nil then
        gfx.line(x + 2, y + 4, x + body_width - 2, y + 4, color)
    elseif level > 0 then
        local fill_width = math.ceil((body_width - 4) * level / 100)
        local fill = colors.normal
        if level <= 10 then
            fill = colors.critical
        elseif level <= 25 then
            fill = colors.low
        end
        if charging then
            fill = colors.charging
        end
        gfx.rectfill(x + 2, y + 2, fill_width, body_height - 4, fill)
    end
end

return battery
