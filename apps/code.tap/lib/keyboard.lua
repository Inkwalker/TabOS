local Keyboard = {}
Keyboard.__index = Keyboard

local keys = {
    escape = {1, 1}, delete = {1, 14}, tab = {3, 1}, w = {3, 3}, o = {3, 10}, backspace = {3, 14},
    shift = {4, 2}, a = {4, 3}, s = {4, 4}, f = {4, 6}, up = {4, 12}, enter = {4, 14}, ctrl = {5, 1}, alt = {5, 2},
    z = {5, 3}, x = {5, 4}, c = {5, 5}, v = {5, 6}, n = {5, 8}, y = {3, 7},
    left = {5, 11}, down = {5, 12}, right = {5, 13},
}

function Keyboard.new()
    return setmetatable({repeat_at = {}, time = 0}, Keyboard)
end

function Keyboard.down(name)
    local key = keys[name]
    return input.key(key[1], key[2])
end

function Keyboard.pressed(name)
    local key = keys[name]
    return input.keyp(key[1], key[2])
end

function Keyboard:advance(dt)
    self.time = self.time + dt
    for name in pairs(self.repeat_at) do
        if not Keyboard.down(name) then self.repeat_at[name] = nil end
    end
end

function Keyboard:repeat_press(name)
    if Keyboard.pressed(name) then
        if Keyboard.down(name) then self.repeat_at[name] = self.time + 0.4 end
        return true
    end
    local next_press = self.repeat_at[name]
    if next_press and self.time >= next_press then
        self.repeat_at[name] = self.time + 0.05
        return true
    end
    return false
end

function Keyboard:reset_repeat()
    self.repeat_at = {}
end

return Keyboard
