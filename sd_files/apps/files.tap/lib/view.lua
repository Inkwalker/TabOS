local View = {rows = 7, row_top = 22, row_height = 19}
local icons = {}
local transparent = gfx.rgb(255, 0, 255)

local colors = {
    background = gfx.rgb(9, 15, 24),
    panel = gfx.rgb(18, 28, 42),
    highlight = gfx.rgb(42, 65, 88),
    text = gfx.rgb(235, 242, 250),
    muted = gfx.rgb(160, 178, 200),
    accent = gfx.rgb(108, 205, 255),
    danger = gfx.rgb(255, 145, 145),
}

local function clip(text, length, keep_end)
    text = text:gsub("%c", " ")
    if #text <= length then return text end
    if keep_end then return "..." .. text:sub(4 - length) end
    return text:sub(1, length - 3) .. "..."
end

local function lines(detail)
    local result = {}
    for raw in (detail .. "\n"):gmatch("(.-)\n") do
        local line = raw:gsub("%c", " ")
        for index = 1, math.max(1, #line), 44 do
            result[#result + 1] = line:sub(index, index + 43)
        end
    end
    return result
end

local function target(state, x, y, w, h, action, row)
    state.targets[#state.targets + 1] = {x = x, y = y, w = w, h = h, action = action, row = row}
end

local function button(state, x, y, w, label, action, selected)
    target(state, x, y, w, 21, action)
    gfx.rectfill(x + 1, y + 1, w - 2, 19, selected and colors.highlight or colors.panel)
    gfx.print(x + math.floor((w - #label * 6) / 2), y + 7, label, colors.accent)
end

local function draw_dialog(state, dialog)
    state.targets = {}
    gfx.rectfill(8, 8, 284, 164, colors.panel)
    gfx.rect(8, 8, 284, 164, colors.accent)
    gfx.print(16, 16, clip(dialog.title, 44), colors.text)
    local options = dialog.options
    local columns = #options <= 4 and #options or 2
    local top = 168 - 22 * math.ceil(#options / columns)
    local width = math.floor(268 / columns)
    for index, option in ipairs(options) do
        local x = 16 + ((index - 1) % columns) * width
        local y = top + ((index - 1) // columns) * 22
        button(state, x, y, width, option[1], option[2], dialog.focus == index)
    end
    if dialog.text then
        gfx.rectfill(16, 54, 268, 22, colors.background)
        gfx.print(20, 61, clip(dialog.text, 43, true), colors.text)
        button(state, 16, 80, 65, "Clear", function() dialog.text = "" end)
    end
    local top_line = dialog.text and 107 or 32
    local bottom_line = top
    if dialog.apply then
        bottom_line = bottom_line - 22
        button(state, 16, bottom_line, 268,
            (dialog.remaining and "[x] " or "[ ] ") .. "Apply to Remaining Conflicts", function()
                dialog.remaining = not dialog.remaining
            end)
    end
    local count = math.max(1, (bottom_line - top_line) // 10)
    local detail = dialog.lines
    if #detail > count then
        count = math.max(1, count - 3)
        local pages = math.ceil(#detail / count)
        if dialog.page > 1 then
            button(state, 16, bottom_line - 22, 60, "Prev", function() dialog.page = dialog.page - 1 end)
        end
        if dialog.page < pages then
            button(state, 224, bottom_line - 22, 60, "Next", function() dialog.page = dialog.page + 1 end)
        end
        gfx.print(135, bottom_line - 15, dialog.page .. "/" .. pages, colors.muted)
    end
    local first = (dialog.page - 1) * count + 1
    for index = first, math.min(first + count - 1, #detail) do
        gfx.print(16, top_line + (index - first) * 10, detail[index], colors.muted)
    end
end

function View.dialog(title, detail, options, cancel)
    return {title = title, lines = lines(detail or ""), options = options,
        cancel = cancel or options[#options][2], page = 1, focus = 1}
end

View.lines = lines

function View.load_icons()
    for _, name in ipairs({"app", "folder", "file"}) do
        icons[name] = assert(gfx.load_sprite(os.path("spr/" .. name .. ".png")))
    end
end

function View.close_icons()
    for name, icon in pairs(icons) do
        icon:close()
        icons[name] = nil
    end
end

function View.draw(state, actions)
    state.targets = {}
    gfx.cls(colors.background)
    gfx.rectfill(0, 0, 300, 22, colors.panel)
    if #state.history > 0 then button(state, 0, 0, 30, "<", actions.back) end
    if state.folder ~= "/" then button(state, 30, 0, 30, "^", actions.parent) end
    target(state, 60, 0, 202, 22, actions.path)
    gfx.print(63, 7, clip(state.folder, 32, true), colors.text)
    button(state, 262, 0, 38, "...", actions.menu)

    if state.read_error then
        gfx.print(10, 56, "Cannot read folder", colors.danger)
        gfx.print(10, 70, clip(state.read_error, 46), colors.muted)
        button(state, 8, 85, 72, "Retry", actions.refresh)
    elseif #state.entries == 0 then
        gfx.print(10, 56, "Folder is empty", colors.muted)
    end
    for row = 1, View.rows do
        local index = state.offset + row
        local entry = state.entries[index]
        if not entry then break end
        local y = View.row_top + (row - 1) * View.row_height
        if index == state.highlight then gfx.rectfill(0, y, 300, View.row_height, colors.highlight) end
        if state.selected_count > 0 then
            gfx.rect(5, y + 5, 9, 9, colors.muted)
            if state.selected[entry.key] then gfx.rectfill(7, y + 7, 5, 5, colors.accent) end
        end
        local icon = entry.app_bundle and icons.app or entry.type == "dir" and icons.folder or icons.file
        gfx.spr(icon, 23, y + 4, transparent)
        gfx.print(42, y + 6, clip(entry.name, 42), colors.text)
        target(state, 0, y, 20, View.row_height, function() actions.select(index) end, index)
        target(state, 20, y, 280, View.row_height, function() actions.open(index) end, index)
    end
    gfx.rectfill(0, 157, 300, 23, colors.panel)
    local count = state.selected_count
    local status = count > 0 and (count .. " selected") or (#state.entries .. " items")
    gfx.print(7, 165, status, colors.muted)
    if count > 0 then button(state, 115, 158, 82, "Actions", actions.selection) end
    if state.clipboard then button(state, 198, 158, 101, "Paste Here", actions.paste) end

    if state.dialog then draw_dialog(state, state.dialog) end
end

return View
