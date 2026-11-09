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
local symbols = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ@#$%&"
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
local digit_duration = 0.2
local current_label, previous_label
local digit_elapsed = digit_duration

local function randomize_stream(stream)
    for row = 1, rows do
        local index = math.random(#symbols)
        stream.letters[row] = symbols:sub(index, index)
    end
    stream.speed = math.random(4, 12)
end

function init()
    for x = 0, gfx.width - column_width, column_width do
        local stream = {
            x = x,
            head = math.random(0, rows + #trail - 1),
            letters = {},
        }
        randomize_stream(stream)
        streams[#streams + 1] = stream
    end
end

local function draw_rain(dt)
    for _, stream in ipairs(streams) do
        stream.head = stream.head + stream.speed * dt
        if stream.head >= rows + #trail then
            stream.head = stream.head % (rows + #trail)
            randomize_stream(stream)
        end
        local head = math.floor(stream.head)
        for offset, color in ipairs(trail) do
            local row = head - offset + 1
            if row >= 0 and row < rows then
                gfx.print(stream.x, row * row_height, stream.letters[row + 1], color)
            end
        end
    end
end

local function draw_clock(dt)
    -- Use the same 24-hour UTC time as the recovery shell.
    local minutes = (sys.get_time() % 86400) // 60
    local label = string.format("%02d:%02d", minutes // 60, minutes % 60)
    if label ~= current_label then
        previous_label = current_label or label
        current_label = label
        digit_elapsed = current_label == previous_label and digit_duration or 0
    else
        digit_elapsed = math.min(digit_duration, digit_elapsed + dt)
    end
    local progress = digit_elapsed / digit_duration
    local x = clock_x
    for index = 1, #label do
        local character = label:sub(index, index)
        local glyph = glyphs[character]
        local previous_glyph = glyphs[previous_label:sub(index, index)]
        for row, pattern in ipairs(glyph) do
            for column = 1, #pattern do
                local was_on = previous_glyph[row]:sub(column, column) == "1"
                local is_on = pattern:sub(column, column) == "1"
                local scale = 0
                if was_on and is_on then
                    scale = 1
                elseif is_on then
                    scale = progress
                elseif was_on then
                    scale = 1 - progress
                end
                local width = math.floor(block_width * scale + 0.5)
                local height = math.floor(block_height * scale + 0.5)
                if width > 0 and height > 0 then
                    gfx.rectfill(x + (column - 1) * block_width + (block_width - width) // 2,
                        clock_y + (row - 1) * block_height + (block_height - height) // 2,
                        width, height, clock_color)
                end
            end
        end
        x = x + (#glyph[1] + 1) * block_width
    end
end

function update(dt)
    if input.keyp(1, 1) then os.exit(); return end
    elapsed = elapsed + dt
    if elapsed < frame_interval then
        return
    end

    gfx.cls()
    draw_rain(elapsed)
    draw_clock(elapsed)
    gfx.flip()
    elapsed = 0
end
