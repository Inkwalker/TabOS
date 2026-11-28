local launch_path = ...
local Bitmap = require("bitmap")

local width, height = gfx.width, gfx.height
local colors = {
    background = gfx.rgb(15, 21, 32),
    panel = gfx.rgb(24, 34, 49),
    button = gfx.rgb(42, 57, 76),
    grid = gfx.rgb(49, 67, 86),
    text = gfx.rgb(239, 246, 255),
    muted = gfx.rgb(166, 186, 208),
    accent = gfx.rgb(110, 231, 196),
    error = gfx.rgb(255, 158, 142),
}
local grid = {x = 62, y = 43, w = 142, h = 101}
local list_rows = 6
local metrics = {
    {"Line", "line_height", 1, 255},
    {"Width", "width", 0, 31},
    {"Rows", "height", 0, 255},
    {"Advance", "advance", 0, 255},
    {"X offset", "x_offset", -128, 127},
    {"Y offset", "y_offset", -128, 127},
}

local data, path, source, dirty
local keys, selected, first, column, row
local modal, gesture, message, message_color
local buttons, redraw = {}, true
local draw

local function clamp(value, low, high)
    return math.max(low, math.min(value, high))
end

local function filename(file)
    return file and file:match("[^/]+$")
end

local function report(text, color)
    message, message_color, redraw = text, color or colors.error, true
end

local function change()
    dirty = true
    report(nil)
end

local function select_glyph(index)
    selected = clamp(index, 1, #keys)
    first = clamp(first, math.max(1, selected - list_rows + 1), selected)
    column, row, redraw = 0, 0, true
end

local function sort_glyphs(preferred)
    keys = {}
    for key in pairs(data.glyphs) do keys[#keys + 1] = key end
    table.sort(keys) -- Valid UTF-8 sorts in code point order.
    local index = 1
    for i, key in ipairs(keys) do
        if key == preferred then index = i; break end
    end
    select_glyph(index)
end

local function document(font, file, info, preferred)
    data, path, source, dirty = font, file, info, false
    first = 1
    sort_glyphs(preferred)
    report(nil)
end

local function new_font()
    document({line_height = 8, glyphs = {
        A = {width = 5, advance = 6, rows = {14, 17, 17, 31, 17, 17, 17}},
        [" "] = {advance = 3, rows = {}},
    }}, nil, nil, "A")
end

local function confirm(title, detail, label, action)
    modal = {kind = "confirm", title = title, detail = detail, label = label, accept = action}
    redraw = true
end

local function replace_document(action)
    if dirty then
        confirm("Discard unsaved edits?", filename(path) or "Untitled.ltab", "Discard", action)
    else
        action()
    end
end

local function open_font(file)
    local info, stat_error = fs.stat(file)
    if not info or info.type ~= "file" then
        report(stat_error or "Choose a font file")
        return
    end
    local font, err = fs.read_table(file)
    if not font then report(err or "Cannot read font"); return end
    local valid, detail = gfx.create_font(font)
    if not valid then report(detail or "Invalid font"); return end
    replace_document(function() document(font, file, info) end)
end

local function picker(mode, on_selected)
    if not os.file_dialog then report("File picker unavailable"); return end
    local options = {mode = mode, directory = path and path:match("^(.+)/[^/]+$") or "/sd"}
    if mode == "save" then
        options.root, options.name = "/sd", filename(path) or "Untitled.ltab"
    end
    local queued, err = os.file_dialog(options, function(file, failure)
        if file then on_selected(file)
        elseif failure then report(failure) end
        gesture = nil
        draw()
    end)
    if not queued then report(err or "Cannot open file picker") end
end

local function same_file(expected, actual)
    if not expected then return not actual end
    return actual and actual.type == "file" and actual.size == expected.size and actual.mtime == expected.mtime
end

local function write_font(file, expected)
    local actual, err, code = fs.stat(file)
    if not actual and code ~= 2 then report(err or "Cannot check save destination"); return end
    if not same_file(expected, actual) then
        report("File changed on disk. Use Save As.")
        return
    end
    local valid, detail = gfx.create_font(data)
    if not valid then report(detail or "Invalid font"); return end
    local ok, warning = fs.write_table(file, data)
    if not ok then report(warning or "Save failed"); return end
    path, source, dirty = file, fs.stat(file), false
    report(warning or "Saved " .. filename(file), warning and colors.error or colors.accent)
end

local function save_as()
    picker("save", function(file)
        local existing, err, code = fs.stat(file)
        if existing and existing.type == "file" then
            confirm("Replace existing file?", filename(file), "Replace", function() write_font(file, existing) end)
        elseif existing or code ~= 2 then
            report(err or "Choose a file destination")
        else
            write_font(file)
        end
    end)
end

local function save()
    if path and path:sub(1, 4) == "/sd/" and source then
        write_font(path, source)
    else
        save_as()
    end
end

-- The renderer validates glyph keys before editing. The device Lua VM omits the UTF-8 library.
local function codepoint(key)
    local a, b, c = key:byte(1, 3)
    if c then return ((a & 0x0f) << 12) | ((b & 0x3f) << 6) | (c & 0x3f) end
    if b then return ((a & 0x1f) << 6) | (b & 0x3f) end
    return a
end

local function glyph_key(code)
    if code < 0x80 then return string.char(code) end
    local last = 0x80 | (code & 0x3f)
    if code < 0x800 then return string.char(0xc0 | (code >> 6), last) end
    return string.char(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), last)
end

local function glyph_label(key, prefix)
    local code = codepoint(key)
    local suffix = code == 32 and " SP" or (code >= 33 and code <= 126 and " " .. key or "")
    return string.format("%s%04X%s", prefix, code, suffix)
end

local function describe_bitmap()
    local glyph = data.glyphs[keys[selected]]
    local w, h = glyph.width or 0, #glyph.rows
    local cell = clamp(math.min(grid.w // math.max(w, 1), grid.h // math.max(h, 1)), 5, 12)
    return glyph, w, h, cell, grid.w // cell, grid.h // cell
end

local function pan(dx, dy)
    local _, w, h, _, visible_w, visible_h = describe_bitmap()
    column = clamp(column + dx, 0, math.max(0, w - visible_w))
    row = clamp(row + dy, 0, math.max(0, h - visible_h))
    redraw = true
end

local function metric_value(field)
    local glyph = data.glyphs[keys[selected]]
    if field == "line_height" then return data.line_height end
    if field == "height" then return #glyph.rows end
    if field == "y_offset" then return glyph.y_offset or -#glyph.rows end
    return glyph[field] or 0
end

local function set_metric(field, value)
    if value == metric_value(field) then return end
    local glyph = data.glyphs[keys[selected]]
    if field == "width" or field == "height" then
        local w, h = glyph.width or 0, #glyph.rows
        if field == "width" then w = value else h = value end
        if value == 0 then
            w, h = 0, 0
        else
            if w == 0 then w = 5 end
            if h == 0 then h = math.min(7, data.line_height) end
        end
        Bitmap.resize(glyph, w, h)
        pan(0, 0)
    elseif field == "line_height" then
        data.line_height = value
    else
        glyph[field] = value
    end
    change()
end

local function number_pad(title, value, hex, low, high, accept)
    modal = {kind = "number", title = title, value = value, hex = hex,
        low = low, high = high, apply = accept, replace = value ~= ""}
    redraw = true
end

local function add_glyph()
    number_pad("Add glyph by code point", "", true, 0, 0xffff, function(code)
        if code >= 0xd800 and code <= 0xdfff then return "Enter a Unicode character" end
        local key = glyph_key(code)
        if data.glyphs[key] then return "That glyph already exists" end
        local previous = data.glyphs[keys[selected]]
        local glyph = {width = previous.width, advance = previous.advance,
            x_offset = previous.x_offset, y_offset = previous.y_offset, rows = {}}
        for row_index = 1, #previous.rows do glyph.rows[row_index] = 0 end
        data.glyphs[key] = glyph
        sort_glyphs(key)
        change()
    end)
end

local function delete_glyph()
    local key = keys[selected]
    if #keys == 1 then report("Keep at least one glyph"); return end
    confirm("Delete this glyph?", glyph_label(key, "U+"), "Delete", function()
        local next_key = keys[selected + 1] or keys[selected - 1]
        data.glyphs[key] = nil
        sort_glyphs(next_key)
        change()
    end)
end

local function printable(key)
    local code = codepoint(key)
    return code >= 32 and (code < 127 or code >= 160)
end

local function sample_text()
    local current = keys[selected]
    local parts = {}
    if printable(current) then parts[1] = current end
    for _, key in ipairs(keys) do
        if #parts == 16 then break end
        if key ~= current and key ~= " " and printable(key) then parts[#parts + 1] = key end
    end
    if #parts == 0 then return "" end
    if #parts == 1 then return parts[1] .. parts[1] .. "\n" .. parts[1] end
    table.insert(parts, (#parts + 1) // 2 + 1, "\n")
    return table.concat(parts)
end

local function preview()
    local font, err = gfx.create_font(data)
    if not font then report(err or "Cannot create preview"); return end
    modal = {kind = "preview", font = font, sample = sample_text(), replace = true}
    redraw = true
end

local function close_modal()
    modal, redraw = nil, true
end

local function pad_digit(digit)
    local entry = modal
    local value = entry.replace and "" or entry.value
    if digit == "-" then
        if value:sub(1, 1) == "-" then value = value:sub(2)
        else value = "-" .. value end
    elseif #value:gsub("-", "") < (entry.hex and 4 or 3) then
        value = value .. digit
    end
    entry.value, entry.replace, entry.error, redraw = value, false, nil, true
end

local function erase_entry()
    local field = modal.kind == "preview" and "sample" or "value"
    local value = modal[field]
    local last = #value
    while last > 1 and (value:byte(last) & 0xc0) == 0x80 do last = last - 1 end
    last = math.max(1, last)
    modal[field], modal.replace, modal.error, redraw = value:sub(1, last - 1), false, nil, true
end

local function append_preview(text)
    if text == "" then return end
    local sample = modal.replace and "" or modal.sample
    if #sample + #text > 60 then return end
    modal.sample, modal.replace, redraw = sample .. text, false, true
end

local function accept_modal()
    if modal.kind == "confirm" then
        local action = modal.accept
        close_modal()
        action()
    elseif modal.kind == "number" then
        local value = tonumber(modal.value, modal.hex and 16 or 10)
        if not value or value < modal.low or value > modal.high then
            modal.error = modal.hex and "Enter 1-4 hex digits" or string.format("Enter %d to %d", modal.low, modal.high)
        else
            modal.error = modal.apply(value)
            if not modal.error then close_modal() end
        end
        redraw = true
    end
end

local function text_at(x, y, value, color)
    gfx.print(x, y, value, color or colors.text)
end

local function button(x, y, w, h, label, action, active, repeatable)
    gfx.rectfill(x, y, w, h, active and colors.accent or colors.button)
    text_at(x + (w - #label * 6) // 2, y + (h - 8) // 2, label,
        active and colors.background or (not action and colors.muted or nil))
    if action then
        buttons[#buttons + 1] = {x = x, y = y, w = w, h = h, action = action, repeatable = repeatable}
    end
end

local function draw_bitmap()
    local glyph, w, h, cell, visible_w, visible_h = describe_bitmap()
    gfx.rectfill(grid.x, grid.y, grid.w, grid.h, colors.panel)
    if w == 0 then
        text_at(grid.x + 14, grid.y + 41, "No bitmap pixels", colors.muted)
        text_at(grid.x + 8, grid.y + 54, "Set Width or Rows", colors.muted)
        return
    end
    local cols, rows = math.min(w - column, visible_w), math.min(h - row, visible_h)
    for y = 0, rows - 1 do
        for x = 0, cols - 1 do
            if Bitmap.pixel(glyph, x + column, y + row) then
                gfx.rectfill(grid.x + x * cell + 1, grid.y + y * cell + 1, cell - 1, cell - 1, colors.accent)
            end
        end
    end
    for x = 0, cols do
        local dx = grid.x + math.min(x * cell, grid.w - 1)
        gfx.line(dx, grid.y, dx, grid.y + math.min(rows * cell, grid.h - 1), colors.grid)
    end
    for y = 0, rows do
        local dy = grid.y + math.min(y * cell, grid.h - 1)
        gfx.line(grid.x, dy, grid.x + math.min(cols * cell, grid.w - 1), dy, colors.grid)
    end
end

local function draw_editor()
    button(4, 4, 41, 19, "New", function() replace_document(new_font) end)
    button(48, 4, 41, 19, "Open", function() picker("open", open_font) end)
    button(92, 4, 41, 19, "Save", save)
    button(136, 4, 55, 19, "Save As", save_as)
    button(194, 4, 61, 19, "Preview", preview)
    button(258, 4, 38, 19, "Exit", function() replace_document(os.exit) end)

    text_at(4, 30, "Glyphs", colors.muted)
    text_at(grid.x, 30, glyph_label(keys[selected], "U+"), colors.accent)
    text_at(210, 30, "Metrics", colors.muted)
    for i = 0, list_rows - 1 do
        local index = first + i
        if keys[index] then
            button(4, 43 + i * 14, 53, 13, glyph_label(keys[index], ""),
                function() select_glyph(index) end, index == selected)
        end
    end
    button(4, 128, 25, 16, "^", selected > 1 and function() select_glyph(selected - list_rows) end, nil, true)
    button(32, 128, 25, 16, "v", selected < #keys and function() select_glyph(selected + list_rows) end, nil, true)
    button(4, 147, 25, 16, "Add", add_glyph)
    button(32, 147, 25, 16, "Del", delete_glyph)

    draw_bitmap()
    local _, w, h, _, visible_w, visible_h = describe_bitmap()
    button(62, 147, 19, 16, "<", column > 0 and function() pan(-1, 0) end, nil, true)
    button(83, 147, 19, 16, ">", column + visible_w < w and function() pan(1, 0) end, nil, true)
    button(104, 147, 19, 16, "^", row > 0 and function() pan(0, -1) end, nil, true)
    button(125, 147, 19, 16, "v", row + visible_h < h and function() pan(0, 1) end, nil, true)
    if w > 0 then text_at(152, 151, string.format("%d,%d", column + 1, row + 1), colors.muted) end

    for i, metric in ipairs(metrics) do
        local label, field, low, high = table.unpack(metric)
        local y, value = 43 + (i - 1) * 17, metric_value(field)
        text_at(210, y + 4, label)
        button(263, y, 33, 15, tostring(value), function()
            number_pad(label .. (field == "line_height" and " height" or ""), tostring(value), false, low, high,
                function(next_value) set_metric(field, next_value) end)
        end)
    end

    gfx.rectfill(0, height - 14, width, 14, colors.panel)
    local status = (dirty and "* " or "") .. (filename(path) or "Untitled.ltab")
    local line = message or status .. " | " .. selected .. "/" .. #keys
    gfx.clip(5, height - 12, width - 10, 10)
    text_at(5, height - 11, line, message and message_color or colors.muted)
    gfx.clip()
end

local function draw_modal()
    gfx.rectfill(5, 5, width - 10, height - 10, colors.panel)
    gfx.rect(5, 5, width - 10, height - 10, colors.grid)
    if modal.kind == "confirm" then
        text_at(17, 22, modal.title, colors.accent)
        gfx.clip(17, 42, width - 34, 12)
        text_at(17, 43, modal.detail)
        gfx.clip()
        button(148, 132, 58, 22, "Cancel", close_modal)
        button(212, 132, 71, 22, modal.label, accept_modal, true)
    elseif modal.kind == "number" then
        text_at(17, 15, modal.title, colors.accent)
        local hint = modal.hex and "Hexadecimal, e.g. 0041 = A" or string.format("Range %d to %d", modal.low, modal.high)
        text_at(17, 30, modal.error or hint, modal.error and colors.error or colors.muted)
        gfx.rectfill(17, 44, 265, 15, colors.background)
        text_at(22, 47, (modal.hex and "U+" or "") .. modal.value, modal.replace and colors.accent or colors.text)
        local symbols = modal.hex and "0123456789ABCDEF" or "0123456789"
        for i = 1, #symbols do
            local digit = symbols:sub(i, i)
            button(17 + (i - 1) % 8 * 33, 64 + (i - 1) // 8 * 25, 30, 22, digit,
                function() pad_digit(digit) end)
        end
        if modal.low < 0 then button(83, 89, 30, 22, "-", function() pad_digit("-") end) end
        button(17, 132, 49, 22, "Bksp", erase_entry)
        button(148, 132, 58, 22, "Cancel", close_modal)
        button(212, 132, 71, 22, "OK", accept_modal, true)
    else
        text_at(17, 15, "Font preview", colors.accent)
        text_at(17, 30, "Type sample text. Enter adds a line.", colors.muted)
        gfx.rectfill(17, 44, 265, 81, colors.background)
        gfx.clip(17, 44, 265, 81)
        gfx.set_font(modal.font)
        local key = keys[selected]
        local x = 23 - math.min(0, data.glyphs[key].x_offset or 0)
        local y = 48
        -- The renderer resets x to the canvas edge after a newline.
        for line in (modal.sample .. "\n"):gmatch("(.-)\n") do
            if y >= 125 then break end
            if line ~= "" then gfx.print(x, y, line, colors.text) end
            y = y + data.line_height
        end
        gfx.set_font()
        gfx.clip()
        button(17, 132, 51, 22, "Sample", function() modal.sample, modal.replace, redraw = sample_text(), true, true end)
        button(73, 132, 42, 22, "Glyph", printable(key) and function() append_preview(key) end)
        button(120, 132, 39, 22, "Line", function() append_preview("\n") end)
        button(164, 132, 43, 22, "Bksp", erase_entry)
        button(212, 132, 71, 22, "Back", close_modal)
    end
end

draw = function()
    buttons = {}
    gfx.cls(colors.background)
    if modal then draw_modal() else draw_editor() end
    redraw = false
end

local function cell_at(x, y)
    local _, w, h, cell, visible_w, visible_h = describe_bitmap()
    local gx, gy = (x - grid.x) // cell, (y - grid.y) // cell
    if gx >= 0 and gx < visible_w and gy >= 0 and gy < visible_h and gx + column < w and gy + row < h then
        return gx + column, gy + row
    end
end

local function paint_to(x, y)
    local glyph = data.glyphs[keys[selected]]
    local g = gesture
    local from_x, from_y = g.x or x, g.y or y
    local dx, dy = x - from_x, y - from_y
    local steps = math.max(math.abs(dx), math.abs(dy), 1)
    for step = 0, steps do
        local px = from_x + (dx * step + steps // 2) // steps
        local py = from_y + (dy * step + steps // 2) // steps
        if Bitmap.paint(glyph, px, py, g.ink) then change() end
    end
    g.x, g.y = x, y
end

local function hit_button(x, y)
    for _, b in ipairs(buttons) do
        if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then return b end
    end
end

local function handle_touch(dt)
    local touches = input.touch()
    if not gesture then
        local touch = touches[1]
        if not touch then return false end
        gesture = {id = touch.id, wait = 0.35}
        local target = hit_button(touch.x, touch.y)
        if target then
            gesture.repeating = target.repeatable
            target.action()
        elseif not modal then
            local x, y = cell_at(touch.x, touch.y)
            if x then
                gesture.ink = not Bitmap.pixel(data.glyphs[keys[selected]], x, y)
                paint_to(x, y)
            end
        end
        return true
    end
    for _, touch in ipairs(touches) do
        if touch.id == gesture.id then
            if gesture.ink ~= nil then
                local x, y = cell_at(touch.x, touch.y)
                if x then paint_to(x, y) else gesture.x, gesture.y = nil, nil end
            elseif gesture.repeating then
                gesture.wait = gesture.wait - dt
                if gesture.wait <= 0 then
                    local target = hit_button(touch.x, touch.y)
                    if target and target.repeatable then target.action() end
                    gesture.wait = 0.07
                end
            end
            return true
        end
    end
    gesture = nil
    return #touches > 0
end

local function handle_keys(text)
    if input.keyp(1, 1) then
        if modal then close_modal() else os.suspend() end
    elseif modal then
        if modal.kind ~= "confirm" and input.keyp(3, 14) then
            erase_entry()
        elseif input.keyp(4, 14) then
            if modal.kind == "preview" then append_preview("\n") else accept_modal() end
        elseif modal.kind == "preview" then
            local room = modal.replace and 60 or 60 - #modal.sample
            append_preview((text:gsub("[^ -~]", "")):sub(1, room))
        elseif modal.kind == "number" then
            local pattern = modal.hex and "[0-9A-F]" or (modal.low < 0 and "[0-9%-]" or "[0-9]")
            for digit in text:upper():gmatch(pattern) do pad_digit(digit) end
        end
    elseif input.key(5, 1) then
        if input.keyp(3, 10) then picker("open", open_font)
        elseif input.keyp(4, 4) then
            if input.key(5, 2) then save_as() else save() end
        end
    elseif input.keyp(4, 12) then select_glyph(selected - 1)
    elseif input.keyp(5, 12) then select_glyph(selected + 1)
    elseif input.keyp(5, 11) then pan(-1, 0)
    elseif input.keyp(5, 13) then pan(1, 0)
    end
end

function init(saved, explicit_args)
    if saved then
        document(saved.data, saved.path, saved.source, saved.glyph)
        dirty = saved.dirty
        pan(saved.column, saved.row)
    else
        new_font()
    end
    if launch_path and (not saved or explicit_args) then open_font(os.path(launch_path)) end
    draw()
end

function save_state()
    return {data = data, path = path, source = source, dirty = dirty,
        glyph = keys[selected], column = column, row = row}
end

function update(dt)
    local text = input.txt()
    if not handle_touch(dt) then handle_keys(text) end
    if redraw then draw() end
end
