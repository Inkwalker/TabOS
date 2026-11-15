local monitor = {}
local last_color

local colors = {
    normal = {0, 255, 0},
    low = {255, 0, 0},
    charging = {255, 191, 0},
}

function monitor.update(level, charging, auto_shutdown)
    if auto_shutdown == true and level == 0 then sys.shutdown() end

    local color = colors.normal
    if charging then
        color = colors.charging
    elseif level ~= nil and level < 20 then
        color = colors.low
    end
    -- Retry failed writes so an attached keyboard receives the current status.
    if color ~= last_color and sys.set_led(1, color[1], color[2], color[3]) then
        last_color = color
    end
end

return monitor
