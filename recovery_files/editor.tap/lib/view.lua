local View = {rows = 16}
local background = gfx.rgb(15, 20, 29)
local panel = gfx.rgb(27, 36, 49)
local gutter_background = gfx.rgb(21, 28, 39)
local foreground = gfx.rgb(226, 232, 240)
local muted = gfx.rgb(131, 150, 172)
local highlight = gfx.rgb(75, 84, 37)
local discard_background = gfx.rgb(55, 29, 34)

function View.draw(doc, state)
    local row, column = doc:position()
    local _, breaks = doc.text:gsub("\n", "")
    local digits = #tostring(breaks + 1)
    local gutter = (digits + 1) * 6
    local width = math.max(1, (gfx.width - gutter) // 6)
    state.top = math.max(1, math.min(state.top, row))
    if row >= state.top + View.rows then state.top = row - View.rows + 1 end
    state.left = math.max(0, math.min(state.left, column))
    if column >= state.left + width then state.left = column - width + 1 end
    gfx.cls(background)
    gfx.rectfill(0, 0, gfx.width, 10, panel)
    gfx.rectfill(0, 10, gutter - 2, View.rows * 10, gutter_background)
    local dirty = doc:dirty()
    local filename = state.path:match("[^/]+$") or state.path
    gfx.print(1, 1, (dirty and "* " or "  ") .. filename:sub(-51), foreground)
    local offset, line = 0, 1
    while line < state.top do
        local ending = doc.text:find("\n", offset + 1, true)
        if not ending then break end
        offset, line = ending, line + 1
    end
    for screen_row = 0, View.rows - 1 do
        if line > breaks + 1 then break end
        local y = 11 + screen_row * 10
        gfx.print(0, y, string.format("%" .. digits .. "d", line), muted)
        local ending = doc.text:find("\n", offset + 1, true) or (#doc.text + 1)
        local display = 0
        for index = offset + 1, ending - 1 do
            local char = doc.text:sub(index, index)
            local cells = char == "\t" and 4 - display % 4 or 1
            local first, last = math.max(display, state.left), math.min(display + cells, state.left + width)
            if first < last then
                local x = gutter + (first - state.left) * 6
                if state.match and index - 1 >= state.match and index - 1 < state.match + #state.query then
                    gfx.rectfill(x, y - 1, (last - first) * 6, 10, highlight)
                end
                if char ~= "\t" then gfx.print(x, y, char, foreground) end
            end
            display = display + cells
            if display >= state.left + width then break end
        end
        offset, line = ending, line + 1
    end
    if state.mode == "edit" and state.blink < 0.5 then
        gfx.rectfill(gutter + (column - state.left) * 6, 11 + (row - state.top) * 10, 1, 8, foreground)
    end
    local position = string.format("%s %d:%d", doc.eol == "\n" and "LF" or "CRLF", row, column + 1)
    local position_x = gfx.width - 1 - #position * 6
    local hint_columns = math.max(0, (position_x - 7) // 6)
    gfx.rectfill(0, 170, gfx.width, 10, panel)
    local hints = "^S Save ^Z Undo ^Y Redo ^F Find"
    if state.mode == "find" then
        hints = ("Find: " .. state.query:gsub("\t", "<TAB>") .. "_"
            .. (state.message and (" [" .. state.message .. "]") or "")):sub(-hint_columns)
    elseif state.mode == "discard" then
        hints = ""
    elseif state.message then
        local shift = math.min(math.max(0, #state.message - hint_columns),
            math.max(0, math.floor((state.message_age - 1) * 8)))
        hints = state.message:sub(shift + 1, shift + hint_columns)
    end
    gfx.print(1, 171, hints:sub(1, hint_columns), foreground)
    gfx.print(position_x, 171, position, foreground)
    if state.mode == "discard" then
        local width, height = 228, 60
        local x, y = (gfx.width - width) // 2, (gfx.height - height) // 2
        gfx.rectfill(x + 3, y + 3, width, height, background)
        gfx.rectfill(x, y, width, height, discard_background)
        gfx.rect(x, y, width, height, muted)
        local title = "Discard changes and exit?"
        local actions = "Y: Exit   N: Cancel"
        gfx.print((gfx.width - #title * 6) // 2, y + 13, title, foreground)
        gfx.print((gfx.width - #actions * 6) // 2, y + 35, actions, foreground)
    end
    gfx.flip()
end

return View
