local Document = require("document")
local Browser = require("browser")
local View = {rows = 18, find_rows = 16, visible_tabs = 4}

local char_width, header_height, row_height = 6, 10, 9
local status_y = header_height + View.rows * row_height
local tab_width, arrow_width = 65, 12
local background = gfx.rgb(15, 20, 29)
local panel = gfx.rgb(27, 36, 49)
local active = gfx.rgb(50, 66, 88)
local selected_text = gfx.rgb(24, 38, 57)
local foreground = gfx.rgb(226, 232, 240)
local muted = gfx.rgb(151, 170, 191)
local accent = gfx.rgb(131, 197, 245)
-- VS Code Dark+ palette, with its teal used for Lua operators and punctuation.
local syntax_colors = {
    p = gfx.rgb(0xD4, 0xD4, 0xD4),
    k = gfx.rgb(0xC5, 0x86, 0xC0),
    f = gfx.rgb(0xDC, 0xDC, 0xAA),
    v = gfx.rgb(0x9C, 0xDC, 0xFE),
    n = gfx.rgb(0xB5, 0xCE, 0xA8),
    o = gfx.rgb(0x4E, 0xC9, 0xB0),
    s = gfx.rgb(0xCE, 0x91, 0x78),
    e = gfx.rgb(0xD7, 0xBA, 0x7D),
    c = gfx.rgb(0x6A, 0x99, 0x55),
}

local function display_path(path)
    -- The canvas font cannot display arbitrary UTF-8 filenames.
    return (path:gsub("[^ -~]", function(byte) return string.format("\\x%02X", byte:byte()) end))
end

local function shorten(text, limit)
    if #text <= limit then return text end
    return text:sub(1, limit - 3) .. "..."
end

local function target(state, x, y, width, height, action)
    state.targets[#state.targets + 1] = {x = x, y = y, width = width, height = height, action = action}
end

local function button(state, x, y, width, height, label, action, selected)
    gfx.rectfill(x, y, width, height, selected and active or panel)
    if label then gfx.print(x + 2, y + (height - 8) // 2, label, selected and accent or foreground) end
    target(state, x, y, width, height, action)
end

function View.hit(state, x, y)
    for _, target in ipairs(state.targets) do
        if x >= target.x and x < target.x + target.width and y >= target.y and y < target.y + target.height then
            return target.action
        end
    end
    if state.mode == "menu" then return "back" end
    if state.mode == "browser" and not state.browser.error and x < 276 and y >= 18 and y < 138 then
        return "browser_list"
    end
    if state.mode == "edit" and state.tabs:current() and y >= header_height and y < status_y then
        return "viewport"
    end
end

local function code_geometry(doc)
    local digits = #tostring(#doc.lines)
    local gutter = (digits + 1) * char_width
    return digits, gutter, (gfx.width - gutter) // char_width
end

function View.reveal_caret(doc, rows)
    rows = rows or View.rows
    local _, _, width = code_geometry(doc)
    doc.top = math.max(1, math.min(doc.top, doc.row, #doc.lines - rows + 1))
    doc.top = math.max(doc.top, doc.row - rows + 1)
    doc.left = math.max(0, math.min(doc.left, doc.column))
    doc.left = math.max(doc.left, doc.column - width + 1)
end

function View.place(doc, x, y, word)
    local _, gutter = code_geometry(doc)
    local row = doc.top + (math.max(header_height, math.min(status_y - 1, y)) - header_height) // row_height
    local column = doc.left + math.max(0, x - gutter) / char_width
    doc:place(row, column, word)
    View.reveal_caret(doc)
end

function View.scroll(doc, top, left, dx, dy, vertical)
    if vertical then
        local limit = math.max(1, #doc.lines - View.rows + 1)
        doc.top = math.max(1, math.min(limit, top - math.floor(dy / row_height + 0.5)))
    else
        local _, _, width = code_geometry(doc)
        local limit = left
        for row = top, math.min(#doc.lines, top + View.rows - 1) do
            limit = math.max(limit, doc:column_at(row) - width + 1)
        end
        doc.left = math.max(0, math.min(limit, left - math.floor(dx / char_width + 0.5)))
    end
end

local function code_line(line, row, left, width, x, y, syntax)
    local text, first, origins = Document.visible_text(line, left, width, syntax ~= nil)
    if not syntax then
        gfx.print(x, y, text, foreground)
        return
    end
    local last = origins and origins[#text] or first + #text - 1
    local colors = syntax:colors(row, first, last)
    local start, color = 1, nil
    for column = 1, #text do
        local index = origins and origins[column] - first + 1 or column
        local next_color = syntax_colors[colors:sub(index, index)]
        if color ~= next_color then
            if color then gfx.print(x + (start - 1) * char_width, y, text:sub(start, column - 1), color) end
            start, color = column, next_color
        end
    end
    if color then gfx.print(x + (start - 1) * char_width, y, text:sub(start), color) end
end

local function code(tab, rows, show_caret)
    local doc = tab.document
    local syntax = tab.lua_source and doc:highlighting() or nil
    local digits, gutter, width = code_geometry(doc)
    local first, start, last, stop = doc:selection()
    gfx.rectfill(0, header_height, gutter - 1, rows * row_height, panel)
    for row = doc.top, math.min(doc.top + rows - 1, #doc.lines) do
        local y = header_height + (row - doc.top) * row_height
        if first and row >= first and row <= last then
            local from = row == first and doc:column_at(row, start) or 0
            local to = row == last and doc:column_at(row, stop) or doc:column_at(row) + 1
            from, to = math.max(0, from - doc.left), math.min(width, to - doc.left)
            if from < to then
                gfx.rectfill(gutter + from * char_width, y, (to - from) * char_width, row_height, selected_text)
            end
        end
        gfx.print((digits - #tostring(row)) * char_width, y, tostring(row), muted)
        code_line(doc.lines[row], row, doc.left, width, gutter, y, syntax)
    end
    if show_caret and doc.row >= doc.top and doc.row < doc.top + rows
        and doc.column >= doc.left and doc.column < doc.left + width then
        local x = gutter + (doc.column - doc.left) * char_width
        local y = header_height + (doc.row - doc.top) * row_height
        gfx.rectfill(x, y, 1, 8, accent)
    end
end

local function tab_strip(state)
    gfx.rectfill(0, 0, gfx.width, header_height, panel)
    local tabs = state.tabs
    local strip_end = arrow_width + tab_width * View.visible_tabs
    if state.first_tab > 1 then
        button(state, 0, 0, arrow_width, header_height, "<", "strip_previous")
    end
    if state.first_tab + View.visible_tabs <= #tabs.items then
        button(state, strip_end, 0, arrow_width, header_height, ">", "strip_next")
    end
    for slot = 0, View.visible_tabs - 1 do
        local index = state.first_tab + slot
        local tab = tabs.items[index]
        if tab then
            local marker = tab.document.modified and "*" or ""
            local name = tab.untitled and ("New " .. tab.untitled) or display_path(tab.name)
            local label = shorten(name, 10 - #marker) .. marker
            button(state, arrow_width + slot * tab_width, 0, tab_width - 1, header_height,
                label, index, index == tabs.active)
        end
    end
    local x = strip_end + arrow_width
    local width = gfx.width - x
    local open = state.mode == "menu"
    button(state, x, 0, width, header_height, nil, "menu", open)
    local bar_width = 12
    for y = 2, 8, 3 do
        gfx.rectfill(x + (width - bar_width) // 2, y, bar_width, 1, open and accent or foreground)
    end
end

local function status(state, doc)
    gfx.rectfill(0, status_y, gfx.width, gfx.height - status_y, panel)
    local position = doc and string.format("%s %d:%d", doc.eol == "\n" and "LF" or "CRLF",
        doc.row, doc.column + 1) or ""
    local x = gfx.width - #position * char_width - 2
    if state.message then
        gfx.print(2, status_y, shorten(display_path(state.message), (gfx.width - 4) // char_width), accent)
    else
        local hint = state.mode == "find" and "Enter Next   Shift+Enter Prev" or "Esc Menu   Ctrl+O Open   Ctrl+F Find"
        gfx.print(2, status_y, hint, muted)
        gfx.print(x, status_y, position, foreground)
    end
end

local menu = {
    {"New", "new"}, {"Open", "open"}, {"Save", "save"}, {"Save As", "save_as"},
    {"Tabs", "tabs"}, {"Close Tab", "close"},
    {"Select All", "select_all"}, {"Cut", "cut"}, {"Copy", "copy"}, {"Paste", "paste"},
    {"Undo", "undo"}, {"Redo", "redo"}, {"Find", "find"}, {"Exit", "exit"},
}

local function draw_menu(state)
    local x, y, width, step = 208, 14, 108, 11
    local padding = 2
    local left, top = x - padding, y - padding
    local panel_width = width + padding * 2
    local panel_height = #menu * step - 1 + padding * 2
    gfx.rectfill(left, top, panel_width, panel_height, background)
    gfx.rect(left, top, panel_width, panel_height, muted)
    for index, item in ipairs(menu) do
        button(state, x, y + (index - 1) * step, width, step - 1, item[1], item[2], index == state.menu_row)
    end
    -- Keep taps on the menu background from dismissing it.
    target(state, left, top, panel_width, panel_height)
end

function View.menu_action(index)
    return menu[index][2]
end

View.menu_rows = #menu

local function draw_find(state)
    local y = header_height + View.find_rows * row_height
    gfx.rectfill(0, y, gfx.width, status_y - y, panel)
    gfx.print(4, y + 5, "Find", foreground)
    local query, caret = state.find:display(24)
    button(state, 34, y + 1, 148, 16, query, nil, true)
    gfx.rectfill(36 + caret * char_width, y + 3, 1, 12, accent)
    button(state, 186, y + 1, 40, 16, "Prev", "find_previous")
    button(state, 230, y + 1, 40, 16, "Next", "find_next")
    button(state, 274, y + 1, 42, 16, "Close", "back")
end

local path_columns, path_rows = 51, 4

function View.path_pages(tab)
    local path = display_path(tab.path or tab.name)
    return math.max(1, math.ceil(#path / (path_columns * path_rows)))
end

local function draw_tabs(state)
    gfx.rectfill(0, header_height, gfx.width, status_y - header_height, background)
    local tabs = state.tabs.items
    for index, tab in ipairs(tabs) do
        local marker = tab.document.modified and "* " or "  "
        local label = marker .. shorten(display_path(tab.path or tab.name), 49)
        button(state, 4, 12 + (index - 1) * 12, 312, 11, label, index, index == state.tab_row)
    end
    local tab = tabs[state.tab_row]
    if tab then
        local path = display_path(tab.path or tab.name)
        local start = (state.path_page - 1) * path_columns * path_rows + 1
        for row = 0, path_rows - 1 do
            local offset = start + row * path_columns
            gfx.print(4, 113 + row * 10, path:sub(offset, offset + path_columns - 1), foreground)
        end
        if state.path_page > 1 then button(state, 4, 154, 52, 16, "< Path", "path_previous") end
        if state.path_page < View.path_pages(tab) then
            button(state, 60, 154, 52, 16, "Path >", "path_next")
        end
        button(state, 186, 154, 70, 16, "Activate", "activate")
    else
        gfx.print(4, 15, "No open tabs", muted)
    end
    button(state, 262, 154, 54, 16, "Back", "back")
end

local function draw_browser(state)
    local browser = state.browser
    local header = browser.saving and "Save As" or "Open"
    gfx.print(4, 5, header, accent)
    local folder = display_path(browser.folder)
    if #folder > 34 then folder = "..." .. folder:sub(-31) end
    gfx.print(60, 5, folder, foreground)
    if browser.folder ~= "/sd" then button(state, 272, 2, 44, 14, "Parent", "browser_parent") end

    if browser.error then
        gfx.print(4, 29, "Folder unavailable", accent)
        local detail = display_path(browser.error)
        for row = 0, 4 do gfx.print(4, 43 + row * 10, detail:sub(row * 51 + 1, (row + 1) * 51), foreground) end
        button(state, 4, 98, 52, 16, "Retry", "browser_retry")
    elseif #browser.entries == 0 then
        gfx.print(4, 29, "Empty folder", muted)
    else
        for index = browser.top, math.min(#browser.entries, browser.top + Browser.rows - 1) do
            local entry = browser.entries[index]
            local label = (entry.directory and "/ " or "  ") .. shorten(display_path(entry.name), 42)
            button(state, 4, 18 + (index - browser.top) * Browser.row_height, 272, Browser.row_height - 1,
                label, index, index == browser.row and browser.focus == "list")
        end
        if browser.top > 1 then button(state, 280, 18, 36, 18, "^", "browser_up") end
        if browser.top + Browser.rows <= #browser.entries then
            button(state, 280, 119, 36, 18, "v", "browser_down")
        end
    end

    if browser.saving and not browser.error then
        local name = display_path(browser.name)
        local caret = #display_path(browser.name:sub(1, browser.caret - 1))
        local first = math.max(0, caret - 43)
        button(state, 4, 139, 272, 16, name == "" and "Filename" or name:sub(first + 1, first + 44),
            "browser_name", browser.focus == "name")
        if browser.focus == "name" and name ~= "" then
            gfx.rectfill(6 + (caret - first) * char_width, 142, 1, 10, accent)
        end
        button(state, 280, 139, 36, 16, "Save", "choose_target")
        gfx.print(4, 165, "Tab Filename   Enter Select / Save", muted)
    else
        gfx.print(4, 165, "Arrows Select   Enter Open", muted)
    end
    button(state, 262, 157, 54, 21, "Back", "back")
end

local dialog_columns, dialog_rows = 50, 8

local function dialog_lines(detail)
    local lines = {}
    for raw in (detail .. "\n"):gmatch("([^\n]*)\n") do
        local line = display_path(raw)
        for start = 1, math.max(#line, 1), dialog_columns do
            lines[#lines + 1] = line:sub(start, start + dialog_columns - 1)
        end
    end
    return lines
end

function View.dialog_pages(prompt)
    return math.ceil(#dialog_lines(prompt.detail) / dialog_rows)
end

local function draw_dialog(state)
    local prompt = state.dialog
    gfx.rectfill(4, 23, 312, 133, panel)
    gfx.rect(4, 23, 312, 133, muted)
    gfx.print(10, 31, prompt.title, accent)
    local lines = dialog_lines(prompt.detail)
    local first = (prompt.page - 1) * dialog_rows
    for row = 1, math.min(dialog_rows, #lines - first) do
        gfx.print(10, 44 + (row - 1) * 9, lines[first + row], foreground)
    end
    if prompt.page > 1 then button(state, 10, 116, 60, 12, "< Detail", "dialog_previous") end
    if first + dialog_rows < #lines then button(state, 244, 116, 66, 12, "Detail >", "dialog_next") end
    local width = 300 // #prompt.buttons
    for index, item in ipairs(prompt.buttons) do
        button(state, 10 + (index - 1) * width, 130, width - 2, 18, item[1], item[2], index == prompt.row)
    end
end

function View.draw(state)
    state.targets = {}
    gfx.cls(background)
    if state.mode == "browser" or (state.mode == "dialog" and state.browser) then
        draw_browser(state)
        if state.mode == "dialog" then
            state.targets = {}
            draw_dialog(state)
        end
        gfx.flip()
        return
    end
    local tab = state.tabs:current()
    local doc = tab and tab.document
    tab_strip(state)
    if doc then
        local rows = state.mode == "find" and View.find_rows or View.rows
        code(tab, rows, state.mode == "edit" and state.blink < 0.5)
    else
        gfx.print(124, 64, "No open tabs", muted)
        button(state, 45, 80, 110, 20, "New  (Ctrl+N)", "new", true)
        button(state, 165, 80, 110, 20, "Open (Ctrl+O)", "open")
    end
    status(state, doc)
    if state.mode ~= "edit" then
        state.targets = {}
        if state.mode == "menu" then draw_menu(state)
        elseif state.mode == "tabs" then draw_tabs(state)
        elseif state.mode == "find" then draw_find(state)
        else draw_dialog(state) end
    end
    gfx.flip()
end

return View
