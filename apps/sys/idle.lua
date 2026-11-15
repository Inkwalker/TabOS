local Idle = {}

local function setting(config, name, default, maximum)
    local value = config[name]
    if type(value) == "number" and value >= 0 and value < math.huge
        and value <= maximum and value == math.floor(value) then
        return value
    end
    return default
end

function Idle.new(raw_input, input, config)
    local dim_after = setting(config, "dim_after_seconds", 60, math.huge)
    local sleep_after = setting(config, "sleep_after_seconds", 180, math.huge)
    local brightness = setting(config, "brightness", 128, 255)
    local dim_brightness = setting(config, "dim_brightness", 32, brightness)
    dim_brightness = math.min(dim_brightness, brightness)
    local elapsed = 0
    local state = "awake"
    local idle = {}

    sys.set_brightness(brightness)

    local function restore()
        if state == "asleep" then sys.wakeup() end
        if state ~= "awake" then sys.set_brightness(brightness) end
        state = "awake"
    end

    local function has_input()
        if #raw_input.touch() > 0 then return true end
        for row = 1, 5 do
            for col = 1, 14 do
                if raw_input.key(row, col) or raw_input.keyp(row, col) then return true end
            end
        end
        return false
    end

    -- Called after polling hardware and before dispatching input to the UI.
    function idle.update(dt, app_active)
        if app_active then
            elapsed = 0
            restore()
            return false
        end
        if has_input() then
            elapsed = 0
            local waking = state == "asleep"
            restore()
            if waking then input.reset() end
            return waking
        end

        elapsed = elapsed + dt
        if elapsed >= sleep_after then
            if state ~= "asleep" then
                sys.sleep()
                state = "asleep"
            end
        elseif elapsed >= dim_after and state == "awake" then
            sys.set_brightness(dim_brightness)
            state = "dimmed"
        end
        return false
    end

    return idle
end

return Idle
