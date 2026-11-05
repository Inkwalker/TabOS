local clock = {}
local seconds_per_day = 86400
local rtc_min_timestamp = 946684800 -- 2000-01-01 00:00 UTC
local label

function clock.refresh()
    local minutes = math.floor((sys.get_time() % seconds_per_day) / 60)
    local time = string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
    local changed = time ~= label
    label = time
    return changed
end

function clock.draw(x, y, color)
    gfx.print(x, y, label, color)
end

function clock.set_time(hour, minute)
    local now = sys.get_time()
    local midnight = math.max(rtc_min_timestamp, now - now % seconds_per_day)
    sys.set_time(midnight + hour * 3600 + minute * 60)
    return now < rtc_min_timestamp
end

return clock
