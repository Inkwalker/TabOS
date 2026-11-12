-- Keep the recovery lifecycle implementation shared by both shells.
package.path = package.path .. ";/rec/sys/?.lua"
local raw_input = input
local input = require("input_gate").new(raw_input)
local clock = require("widgets.clock")
local battery = require("widgets.battery")
local apps, targets = {}, {}
local page = 1
local message
local status_elapsed = 0
local touch_held = true -- Wait for boot/transition contacts to be released.
local pressed
local press_elapsed = 0
local app_menu
local confirm_forget = false

local colors = {
    background = gfx.rgb(9, 15, 24),
    panel = gfx.rgb(12, 19, 29),
    tile = gfx.rgb(25, 37, 54),
    pressed = gfx.rgb(43, 64, 88),
    accent = gfx.rgb(108, 205, 255),
    text = gfx.rgb(235, 242, 250),
    muted = gfx.rgb(155, 174, 195),
    error = gfx.rgb(255, 92, 97),
}
local margin, header, footer = 8, 22, 24
local columns = math.max(1, math.floor((gfx.width - margin * 2) / 72))
local rows = math.max(1, math.floor((gfx.height - header - footer) / 60))
local per_page = columns * rows
local cell_width = math.floor((gfx.width - margin * 2) / columns)
local cell_height = math.floor((gfx.height - header - footer) / rows)

local function show_error(err)
    message = tostring(err)
end

local runner = require("app_runner").new(raw_input, show_error)

local function refresh_status()
    local clock_changed = clock.refresh()
    local battery_changed = battery.refresh()
    status_elapsed = 0
    return clock_changed or battery_changed
end

local function page_count()
    return math.max(1, math.ceil(#apps / per_page))
end

local function scan_apps()
    apps = {}
    local directories = {"/sd"}
    while #directories > 0 do
        local directory = table.remove(directories)
        local entries, err = fs.list(directory)
        if not entries then
            show_error(err or ("Cannot read " .. directory))
        else
            for _, entry in ipairs(entries) do
                if entry.type == "dir" then
                    local name = entry.name
                    local path = directory .. "/" .. name
                    if name:sub(-4):lower() == ".tap" then
                        local main = fs.stat(path .. "/app.lua")
                        if main and main.type == "file" then
                            apps[#apps + 1] = {name = name:sub(1, -5), path = path}
                        end
                    else
                        directories[#directories + 1] = path
                    end
                end
            end
        end
    end
    table.sort(apps, function(a, b)
        local left, right = a.name:lower(), b.name:lower()
        if left == right then return a.path < b.path end
        return left < right
    end)
    page = math.min(page, page_count())
end

local function shortened(text, limit)
    if #text <= limit then return text end
    return text:sub(1, math.max(0, limit - 3)) .. "..."
end

local function centered(x, y, width, text, color)
    gfx.print(x + math.floor((width - #text * 6) / 2), y, text, color)
end

local function target(x, y, width, height, action)
    local item = {x = x, y = y, width = width, height = height, action = action}
    targets[#targets + 1] = item
    return item
end

local function contains(item, x, y)
    return x >= item.x and x < item.x + item.width
        and y >= item.y and y < item.y + item.height
end

local function draw()
    targets = {}
    gfx.cls(colors.background)
    gfx.rectfill(0, 0, gfx.width, 16, colors.panel)
    gfx.print(8, 4, "TabOS", colors.text)
    clock.draw(gfx.width - 60, 4, colors.text)
    battery.draw(gfx.width - 24, 4, colors.text)

    local first = (page - 1) * per_page + 1
    for index = first, math.min(#apps, first + per_page - 1) do
        local app = apps[index]
        local slot = index - first
        local x = margin + (slot % columns) * cell_width
        local y = header + math.floor(slot / columns) * cell_height
        local width, height = cell_width - 4, cell_height - 4
        target(x, y, width, height, {app = app})
        local held = pressed and pressed.action.app == app
        gfx.rectfill(x, y, width, height, held and colors.pressed or colors.tile)
        -- A built-in icon works for every app without requiring a manifest/PNG.
        local icon_x = x + math.floor((width - 28) / 2)
        gfx.rectfill(icon_x, y + 6, 28, 28, colors.accent)
        centered(icon_x, y + 16, 28, app.name:sub(1, 1):upper(), colors.background)
        if runner:has_session(app.path) then
            gfx.rectfill(icon_x + 20, y + 6, 8, 8, colors.background)
            gfx.rectfill(icon_x + 22, y + 8, 1, 4, colors.text)
            gfx.rectfill(icon_x + 25, y + 8, 1, 4, colors.text)
        end
        local label = shortened(app.name, math.floor((width - 4) / 6))
        centered(x, y + 42, width, label, colors.text)
    end
    if #apps == 0 then
        centered(0, header + 34, gfx.width, "No .tap apps on SD card", colors.muted)
        centered(0, header + 48, gfx.width, "Copy apps, then tap Refresh", colors.muted)
    end

    local y = gfx.height - footer
    gfx.rectfill(0, y, gfx.width, footer, colors.panel)
    local function button(x, width, label, action, enabled)
        if enabled then target(x, y, width, footer, action) end
        centered(x, y + 8, width, label, enabled and colors.text or colors.muted)
    end
    button(0, 60, "< Prev", {page = -1}, page > 1)
    button(60, 60, "Next >", {page = 1}, page < page_count())
    centered(120, y + 8, gfx.width - 194, page .. "/" .. page_count(), colors.muted)
    button(gfx.width - 74, 74, "Refresh", {refresh = true}, true)

    if app_menu then
        targets = {}
        local suspended = runner:has_session(app_menu.path)
        gfx.rectfill(24, 26, gfx.width - 48, 126, colors.panel)
        gfx.rect(24, 26, gfx.width - 48, 126, colors.accent)
        gfx.print(32, 34, shortened(app_menu.name, 40), colors.text)
        local function menu_button(y, label, action)
            target(32, y, gfx.width - 64, 22, action)
            gfx.print(40, y + 6, label, colors.text)
        end
        if confirm_forget then
            gfx.print(32, 50, "Forget session? Unsaved work is lost.", colors.error)
            menu_button(70, "Forget Session", {forget = app_menu})
            menu_button(118, "Cancel", {cancel_menu = true})
        else
            gfx.print(32, 50, suspended and "Suspended" or "Ready", colors.muted)
            menu_button(70, suspended and "Resume" or "Open", {app = app_menu})
            if suspended then menu_button(94, "Forget Session...", {confirm_forget = true}) end
            menu_button(118, "Cancel", {cancel_menu = true})
        end
    end
    if message then
        targets = {}
        target(0, 0, gfx.width, gfx.height, {dismiss = true})
        gfx.rectfill(8, 28, gfx.width - 16, gfx.height - 60, colors.panel)
        gfx.rect(8, 28, gfx.width - 16, gfx.height - 60, colors.error)
        gfx.print(16, 36, "Shell message", colors.error)
        local text = message:gsub("[%c]", " ")
        local width = math.max(1, math.floor((gfx.width - 32) / 6))
        local count = math.max(1, math.floor((gfx.height - 108) / 10))
        for row = 1, count do
            local line = text:sub((row - 1) * width + 1, row * width)
            if row == count and #text > row * width then
                line = shortened(text:sub((row - 1) * width + 1), width)
            end
            gfx.print(16, 52 + (row - 1) * 10, line, colors.text)
        end
        gfx.print(16, gfx.height - 48, "Tap to dismiss", colors.accent)
    end
    gfx.flip()
end

local function restore_shell()
    input.reset()
    touch_held, pressed = true, nil
    app_menu, confirm_forget = nil, false
    scan_apps()
    refresh_status()
    draw()
end

function init()
    restore_shell()
end

function update(dt)
    input.update()
    if runner:active() then
        runner:update(dt)
        if not runner:active() then
            restore_shell()
        elseif message then
            -- Rejection leaves the app alive; show its reason above the app's frame.
            gfx.rectfill(0, 0, gfx.width, 16, colors.panel)
            gfx.print(4, 4, shortened(message:gsub("[%c]", " "), math.floor((gfx.width - 8) / 6)), colors.error)
            gfx.flip()
        end
        return
    end
    input.txt() -- The launcher has no text input; do not accumulate keystrokes.
    status_elapsed = status_elapsed + dt
    local dirty = status_elapsed >= 0.5 and refresh_status()
    local contacts = input.touch()
    if #contacts > 0 then
        local contact = contacts[1]
        if not touch_held and #contacts == 1 then
            for _, item in ipairs(targets) do
                if contains(item, contact.x, contact.y) then
                    pressed = item
                    pressed.id = contact.id
                    press_elapsed = 0
                    dirty = true
                    break
                end
            end
        elseif pressed and (#contacts ~= 1 or contact.id ~= pressed.id
            or not contains(pressed, contact.x, contact.y)) then
            pressed = nil
            dirty = true
        end
        if pressed and pressed.action.app and not app_menu then
            press_elapsed = press_elapsed + dt
            if press_elapsed >= 0.6 then
                app_menu = pressed.action.app
                confirm_forget, pressed = false, nil
                dirty = true
            end
        end
        touch_held = true
    else
        local action = pressed and pressed.action
        touch_held, pressed = false, nil
        if action then
            if action.app then
                -- Launch on release so the app cannot inherit the launcher tap.
                local ok, err = pcall(runner.launch, runner, action.app.path, {})
                input.reset()
                if not ok then show_error(err) end
                if not runner:active() then restore_shell() end
                return
            elseif action.confirm_forget then
                confirm_forget = true
            elseif action.forget then
                runner:forget(action.forget.path)
                app_menu, confirm_forget = nil, false
            elseif action.cancel_menu then
                app_menu, confirm_forget = nil, false
            elseif action.page then
                page = math.max(1, math.min(page_count(), page + action.page))
            elseif action.refresh then
                message = nil
                scan_apps()
            elseif action.dismiss then
                message = nil
            end
            dirty = true
        end
    end
    if dirty then draw() end
end
