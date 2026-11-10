local Gate = {}

-- Suppress keys held across an ownership change until they have been released.
function Gate.new(raw)
    local blocked = {}
    local touch_blocked = true
    local gate = setmetatable({}, {__index = raw})
    function gate.reset()
        blocked = {}
        touch_blocked = true
        for row = 1, 5 do
            for col = 1, 14 do
                if raw.key(row, col) then blocked[row .. ":" .. col] = {row, col} end
            end
        end
        raw.txt()
    end
    function gate.refresh()
        if #raw.touch() == 0 then touch_blocked = false end
        for id, key in pairs(blocked) do
            if not raw.key(key[1], key[2]) then blocked[id] = nil end
        end
    end
    function gate.touch()
        if touch_blocked then return {} end
        return raw.touch()
    end
    for _, name in ipairs({"key", "keyp", "keyr"}) do
        gate[name] = function(row, col)
            return not blocked[row .. ":" .. col] and raw[name](row, col)
        end
    end
    function gate.txt()
        local text = raw.txt()
        -- Modifiers held at launch should not suppress newly typed characters.
        for _, key in pairs(blocked) do
            local modifier = (key[1] == 4 and key[2] <= 2) or (key[1] == 5 and key[2] <= 2)
            if not modifier then return "" end
        end
        return text
    end
    function gate.update()
        raw.update()
        gate.refresh()
    end
    gate.reset()
    return gate
end

return Gate
