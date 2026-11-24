local KeyboardManager = {}
KeyboardManager.__index = KeyboardManager

local arrows = {{"left", 5, 11}, {"right", 5, 13}, {"up", 4, 12}, {"down", 5, 12}}
local repeat_delay, repeat_interval = 0.4, 0.05

function KeyboardManager.new(actions)
    return setmetatable({actions = actions, time = 0, repeat_at = {}}, KeyboardManager)
end

function KeyboardManager:reset_repeat()
    for name in pairs(self.repeat_at) do self.repeat_at[name] = nil end
end

local function arrow_pressed(keyboard, name, row, col)
    local held = input.key(row, col)
    if input.keyp(row, col) then
        keyboard.repeat_at[name] = held and keyboard.time + repeat_delay or nil
        return true
    end
    local next_press = keyboard.repeat_at[name]
    if not held then
        keyboard.repeat_at[name] = nil
    elseif next_press and keyboard.time >= next_press then
        keyboard.repeat_at[name] = keyboard.time + repeat_interval
        return true
    end
    return false
end

function KeyboardManager:update(dt)
    self.time = self.time + dt
    local text = input.txt()
    if input.keyp(1, 1) then
        self.actions.close()
        return true
    end
    local control = input.key(5, 1)
    if control then
        if input.keyp(3, 10) then
            self.actions.open()
            return true
        end
        if input.keyp(4, 4) then
            self.actions.save()
            return true
        end
        if input.keyp(5, 3) then
            self.actions.undo()
            return true
        end
        if input.keyp(3, 7) then
            self.actions.redo()
            return true
        end
    end

    local handled = false
    -- The backtick key is also tilde with Sym or Aa held.
    local draw_held = input.key(2, 1)
        and not (control or input.key(5, 2) or input.key(4, 1) or input.key(4, 2))
    for _, arrow in ipairs(arrows) do
        local name, row, col = table.unpack(arrow)
        if arrow_pressed(self, name, row, col) then
            self.actions.tool_key(name, draw_held)
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
