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

local block_width = math.max(1, gfx.width * 9 // 170)
local block_height = block_width
local clock_x = (gfx.width - 17 * block_width) // 2
local clock_y = (gfx.height - 5 * block_height) // 2
local clock_color = gfx.rgb(120, 240, 195)

local column_width, row_height = 8, 10
local rows = gfx.height // row_height
local symbols = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local trail = {
    gfx.rgb(100, 240, 145),
    gfx.rgb(0, 153, 62),
    gfx.rgb(0, 116, 45),
    gfx.rgb(0, 85, 30),
    gfx.rgb(0, 61, 23),
    gfx.rgb(0, 42, 14),
}
local streams = {}
local frame_interval = 1 / 25
local elapsed = frame_interval

function init()
    for x = 0, gfx.width - column_width, column_width do
        local letters = {}
        for row = 1, rows do
            local index = math.random(#symbols)
            letters[row] = symbols:sub(index, index)
        end
        streams[#streams + 1] = {
            x = x,
            head = math.random(0, rows + #trail - 1),
            speed = math.random(4, 12),
            letters = letters,
        }
    end
end

local function draw_rain(dt)
    for _, stream in ipairs(streams) do
        stream.head = (stream.head + stream.speed * dt) % (rows + #trail)
        local head = math.floor(stream.head)
        for offset, color in ipairs(trail) do
            local row = head - offset + 1
            if row >= 0 and row < rows then
                gfx.print(stream.x, row * row_height, stream.letters[row + 1], color)
            end
        end
    end
end

local function draw_clock()
    -- Use the same 24-hour UTC time as the recovery shell.
    local minutes = (sys.get_time() % 86400) // 60
    local label = string.format("%02d:%02d", minutes // 60, minutes % 60)
    local x = clock_x
    for character in label:gmatch(".") do
        local glyph = glyphs[character]
        for row, pattern in ipairs(glyph) do
            for first, last in pattern:gmatch("()1+()") do
                gfx.rectfill(x + (first - 1) * block_width,
                    clock_y + (row - 1) * block_height,
                    (last - first) * block_width, block_height, clock_color)
            end
        end
        x = x + (#glyph[1] + 1) * block_width
    end
end

function update(dt)
    elapsed = elapsed + dt
    if elapsed < frame_interval then
        return
    end

    gfx.cls()
    draw_rain(elapsed)
    draw_clock()
    gfx.flip()
    elapsed = 0
end
