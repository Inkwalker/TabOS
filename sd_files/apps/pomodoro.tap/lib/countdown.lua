local colors = require("theme")

local Countdown = {}
Countdown.__index = Countdown

-- The clock.tap glyphs occupy a 17-by-5 grid when laid out as MM:SS.
local glyphs = {
    ["0"] = {"111", "101", "101", "101", "111"},
    ["1"] = {"001", "001", "001", "001", "001"},
    ["2"] = {"111", "001", "111", "100", "111"},
    ["3"] = {"111", "001", "111", "001", "111"},
    ["4"] = {"101", "101", "111", "001", "001"},
    ["5"] = {"111", "100", "111", "001", "111"},
    ["6"] = {"111", "100", "111", "101", "111"},
    ["7"] = {"111", "001", "001", "001", "001"},
    ["8"] = {"111", "101", "111", "101", "111"},
    ["9"] = {"111", "101", "111", "001", "111"},
    [":"] = {"0", "1", "0", "1", "0"},
}
local columns, rows = 17, 5
local max_block = 14
local transition_duration = 0.12

function Countdown.new(x, y, width, height)
    local block = math.min(max_block, width // columns, height // rows)
    return setmetatable({
        x = x + (width - columns * block) // 2,
        y = y + (height - rows * block) // 2,
        block = block,
        elapsed = transition_duration,
    }, Countdown)
end

function Countdown:update(seconds, dt, visible)
    local changed = seconds ~= self.seconds
    if changed then
        local text = string.format("%02d:%02d", seconds // 60, seconds % 60)
        self.elapsed = self.text and 0 or transition_duration
        self.previous_text = self.text or text
        self.text = text
        self.seconds = seconds
    end
    if not visible then
        self.elapsed = transition_duration
        return false
    end
    if changed then return true end
    if self.elapsed < transition_duration and dt > 0 then
        self.elapsed = math.min(transition_duration, self.elapsed + dt)
        return true
    end
    return false
end

function Countdown:draw()
    local x, y, block = self.x, self.y, self.block
    local progress = self.elapsed / transition_duration
    for index = 1, #self.text do
        local glyph = glyphs[self.text:sub(index, index)]
        local previous = glyphs[self.previous_text:sub(index, index)]
        for row, pattern in ipairs(glyph) do
            for column = 1, #pattern do
                local was_on = previous[row]:sub(column, column) == "1"
                local is_on = pattern:sub(column, column) == "1"
                local scale = 0
                if was_on and is_on then
                    scale = 1
                elseif is_on then
                    scale = progress
                elseif was_on then
                    scale = 1 - progress
                end
                local size = math.floor(block * scale + 0.5)
                if size > 0 then
                    local inset = (block - size) // 2
                    gfx.rectfill(x + (column - 1) * block + inset,
                        y + (row - 1) * block + inset, size, size, colors.text)
                end
            end
        end
        x = x + (#glyph[1] + 1) * block
    end
end

return Countdown
