local KeyboardManager = {}
KeyboardManager.__index = KeyboardManager

local arrows = {{"left", 5, 11}, {"right", 5, 13}, {"up", 4, 12}, {"down", 5, 12}}

function KeyboardManager.new(actions)
    return setmetatable({actions = actions}, KeyboardManager)
end

function KeyboardManager:update()
    local text = input.txt()
    if input.keyp(1, 1) then
        self.actions.close()
        return true
    end
    if input.key(5, 1) then
        if input.keyp(3, 10) then
            self.actions.open()
            return true
        end
        if input.keyp(4, 4) then
            self.actions.save()
            return true
        end
    end

    local handled = false
    for _, arrow in ipairs(arrows) do
        if input.keyp(arrow[2], arrow[3]) then
            self.actions.tool_key(arrow[1])
            handled = true
        end
    end
    -- TabOS decodes the physical key and its modifiers into the typed symbol.
    for symbol in text:gmatch("[+~%-`]") do
        if symbol == "`" then
            self.actions.tool_key(symbol)
        else
            self.actions.zoom(symbol == "+" and 1 or -1)
        end
        handled = true
    end
    return handled
end

return KeyboardManager
