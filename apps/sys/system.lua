-- Keep the recovery lifecycle implementation shared by both shells.
package.path = package.path .. ";/rec/sys/?.lua"
local raw_input = input
local input = require("input_gate").new(raw_input)
local config = fs.read_table("/sd/sys/config.ltab") or {}
local idle = require("idle").new(raw_input, input, config)
local clock = require("widgets.clock")
local battery = require("widgets.battery")
local battery_monitor = require("battery_monitor")
local apps, targets = {}, {}
local page = 1
local message
local message_age = 0
local status_elapsed = 0
local touch_held = true -- Wait for boot/transition contacts to be released.
local pressed
local press_elapsed = 0
local app_menu
local confirm_forget = false
local app_frame
local active_app
local opened_apps = {}
local task_apps = {}
local chooser, pending_open
local Registry = require("associations")
local associations = Registry.new(config.files_app)
local Taskbar = require("taskbar")
local taskbar = Taskbar.new()
local desktop_width = 300

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
local columns = math.max(1, math.floor((desktop_width - margin * 2) / 72))
local rows = math.max(1, math.floor((gfx.height - header - footer) / 60))
local per_page = columns * rows
local cell_width = math.floor((desktop_width - margin * 2) / columns)
local cell_height = math.floor((gfx.height - header - footer) / rows)

local function show_error(err)
    message = tostring(err)
    message_age = 0
end

local app_input = setmetatable({touch = function()
    local contacts = raw_input.touch()
    return app_frame and taskbar:app_touch(contacts) or contacts
end}, {__index = raw_input})
local runner = require("app_runner").new(app_input, show_error, {
    open = function(request) pending_open = request end,
    refresh = function() return associations:refresh() end,
})

local function refresh_task_apps()
    local known, extra = {}, {}
    local active_key = active_app and fs.fat_name_key(active_app.path)
    task_apps = {}
    for _, app in ipairs(apps) do
        task_apps[#task_apps + 1] = app
        known[fs.fat_name_key(app.path)] = true
    end
    for path, app in pairs(opened_apps) do
        if runner:has_session(app.path) then
            if not known[path] then extra[#extra + 1] = app end
        elseif path ~= active_key then
            opened_apps[path] = nil
        end
    end
    table.sort(extra, function(a, b) return a.path < b.path end)
    for _, app in ipairs(extra) do task_apps[#task_apps + 1] = app end
end

local function refresh_status()
    local clock_changed = clock.refresh()
    local battery_changed, level, charging = battery.refresh()
    battery_monitor.update(level, charging, config.auto_shutdown)
    status_elapsed = 0
    return clock_changed or battery_changed
end

local function page_count()
    return math.max(1, math.ceil(#apps / per_page))
end

local function scan_apps()
    for _, app in ipairs(apps) do
        if app.icon then app.icon:close() end
    end
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
                            local app = {name = name:sub(1, -5), path = path, window = false}
                            local manifest = fs.read_table(path .. "/manifest.ltab")
                            if manifest then
                                app.window = manifest.window == true
                                if type(manifest.name) == "string" and manifest.name:find("%S")
                                    and not manifest.name:find("%c") then
                                    app.name = manifest.name
                                end
                                local icon = manifest.icon
                                if type(icon) == "string" and icon ~= ""
                                    and not icon:find("[%c\\:]") and icon:sub(1, 1) ~= "/" then
                                    local safe = true
                                    for part in icon:gmatch("[^/]+") do
                                        if part == ".." then safe = false end
                                    end
                                    if safe then
                                        app.icon = gfx.load_sprite(path .. "/" .. icon)
                                        if app.icon and (app.icon.width > 28 or app.icon.height > 28) then
                                            app.icon:close()
                                            app.icon = nil
                                        end
                                    end
                                end
                            end
                            apps[#apps + 1] = app
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
    gfx.rectfill(0, 0, desktop_width, 16, colors.panel)
    gfx.print(8, 4, "TabOS", colors.text)
    clock.draw(desktop_width - 36, 4, colors.text)

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
        local icon_x = x + math.floor((width - 28) / 2)
        if app.icon then
            gfx.spr(app.icon, icon_x + math.floor((28 - app.icon.width) / 2),
                y + 6 + math.floor((28 - app.icon.height) / 2))
        else
            gfx.rectfill(icon_x, y + 6, 28, 28, colors.accent)
            centered(icon_x, y + 16, 28, app.name:sub(1, 1):upper(), colors.background)
        end
        if runner:has_session(app.path) then
            gfx.rectfill(icon_x + 20, y + 6, 8, 8, colors.background)
            gfx.rectfill(icon_x + 22, y + 8, 1, 4, colors.text)
            gfx.rectfill(icon_x + 25, y + 8, 1, 4, colors.text)
        end
        local label = shortened(app.name, math.floor((width - 4) / 6))
        centered(x, y + 42, width, label, colors.text)
    end
    if #apps == 0 then
        centered(0, header + 34, desktop_width, "No .tap apps on SD card", colors.muted)
        centered(0, header + 48, desktop_width, "Copy apps, then tap Refresh", colors.muted)
    end

    local y = gfx.height - footer
    gfx.rectfill(0, y, desktop_width, footer, colors.panel)
    local function button(x, width, label, action, enabled)
        if enabled then target(x, y, width, footer, action) end
        centered(x, y + 8, width, label, enabled and colors.text or colors.muted)
    end
    button(0, 60, "< Prev", {page = -1}, page > 1)
    button(60, 60, "Next >", {page = 1}, page < page_count())
    centered(120, y + 8, desktop_width - 194, page .. "/" .. page_count(), colors.muted)
    button(desktop_width - 74, 74, "Refresh", {refresh = true}, true)

    if app_menu then
        targets = {}
        local suspended = runner:has_session(app_menu.path)
        gfx.rectfill(24, 26, desktop_width - 48, 126, colors.panel)
        gfx.rect(24, 26, desktop_width - 48, 126, colors.accent)
        gfx.print(32, 34, shortened(app_menu.name, 40), colors.text)
        local function menu_button(y, label, action)
            target(32, y, desktop_width - 64, 22, action)
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
    if chooser then
        targets = {}
        gfx.rectfill(8, 8, 284, 164, colors.panel)
        gfx.rect(8, 8, 284, 164, colors.accent)
        gfx.print(16, 16, "Open With", colors.text)
        local name = chooser.path:match("[^/]+$")
        gfx.print(16, 29, shortened(name, 44), colors.muted)
        local first = math.floor((chooser.selected - 1) / 4) * 4 + 1
        for index = first, math.min(first + 3, #chooser.candidates) do
            local y = 42 + (index - first) * 20
            local app = chooser.candidates[index]
            target(16, y, 268, 20, {candidate = index})
            if index == chooser.selected then gfx.rectfill(16, y, 268, 20, colors.pressed) end
            gfx.print(22, y + 6, shortened(app.name, 27), colors.text)
            gfx.print(191, y + 6, shortened(app.path:match("[^/]+$"), 15), colors.muted)
        end
        local function choice(x, y, w, label, action)
            target(x, y, w, 22, action)
            centered(x, y + 7, w, label, colors.accent)
        end
        if first > 1 then choice(16, 122, 46, "Prev", {candidate = first - 4}) end
        if first + 4 <= #chooser.candidates then
            choice(238, 122, 46, "Next", {candidate = first + 4})
        end
        centered(62, 129, 176, chooser.selected .. "/" .. #chooser.candidates, colors.muted)
        choice(16, 144, 90, "Just Once", {open_choice = "once"})
        choice(106, 144, 88, "Always", {open_choice = "always"})
        choice(194, 144, 90, "Cancel", {cancel_chooser = true})
    end
    if message then
        targets = {}
        target(0, 0, desktop_width, gfx.height, {dismiss = true})
        gfx.rectfill(8, 28, desktop_width - 16, gfx.height - 60, colors.panel)
        gfx.rect(8, 28, desktop_width - 16, gfx.height - 60, colors.error)
        gfx.print(16, 36, "Shell message", colors.error)
        local text = message:gsub("[%c]", " ")
        local width = math.max(1, math.floor((desktop_width - 32) / 6))
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
end

local function release_app_frame()
    if app_frame then
        gfx.target()
        app_frame:close()
        app_frame = nil
    end
    active_app = nil
    taskbar:reset()
end

local function launch_app(app, args)
    release_app_frame()
    message = nil
    local ok, err = pcall(function()
        if app.window then
            app_frame = assert(gfx.create_sprite(300, 180))
            gfx.target(300, 180)
        end
        active_app = app
        opened_apps[fs.fat_name_key(app.path)] = {
            path = app.path, name = app.name, window = app.window,
        }
        runner:launch(app.path, args)
    end)
    input.reset()
    refresh_task_apps()
    if not ok then show_error(err) end
end

local function restore_shell(refresh_launcher)
    release_app_frame()
    input.reset()
    touch_held, pressed = true, nil
    app_menu, confirm_forget = nil, false
    if refresh_launcher then scan_apps() end
    refresh_task_apps()
    refresh_status()
    draw()
end

function init()
    scan_apps()
    associations:refresh()
    restore_shell()
end

local function open_result(result, err)
    if result and result.app then
        launch_app(result.app, result.args)
        if result.warning and not message then show_error(result.warning) end
    elseif result then
        chooser = result
        chooser.selected = 1
    else
        show_error(err)
    end
end

local function process_open()
    local request = pending_open
    pending_open = nil
    message = nil
    open_result(associations:resolve(request))
end

local function choose_handler(always)
    local request = chooser
    chooser = nil
    open_result(associations:choose(request.path, request.extension,
        request.candidates[request.selected], always))
    if not runner:active() then restore_shell() end
end

local function update_system(dt)
    input.update()
    if idle.update(dt, runner:active()) then
        touch_held, pressed = true, nil
    end
    status_elapsed = status_elapsed + dt
    local dirty = status_elapsed >= 0.5 and refresh_status()
    if pending_open and not runner:active() then
        process_open()
        if not runner:active() then restore_shell() end
        return
    elseif runner:active() then
        message_age = message_age + dt
        if message_age >= 4 then message = nil end
        local switch_to = app_frame and taskbar:route(input.touch())
        local previous = active_app
        if switch_to then
            message = nil
            runner:suspend()
        end
        runner:update(dt)
        if not runner:active() then
            local opening = pending_open ~= nil
            if pending_open then
                process_open()
            elseif switch_to and switch_to ~= Taskbar.HOME and runner:has_session(previous.path) then
                launch_app(switch_to)
            end
            if not runner:active() then restore_shell(not opening) end
        end
        return
    end
    input.txt() -- The launcher has no text input; do not accumulate keystrokes.
    local contacts = input.touch()
    local selected = taskbar:route(contacts)
    if selected and selected ~= Taskbar.HOME and not chooser and not message then
        app_menu, confirm_forget = nil, false
        launch_app(selected)
        if not runner:active() then restore_shell(not pending_open) end
        return
    end
    if chooser and not message then
        if input.keyp(1, 1) then
            chooser, pressed = nil, nil
            touch_held = #contacts > 0
            draw()
            return
        elseif input.keyp(4, 14) then
            choose_handler(false)
            return
        elseif input.keyp(4, 12) or input.keyp(5, 12) then
            local direction = input.keyp(4, 12) and -1 or 1
            chooser.selected = math.max(1, math.min(#chooser.candidates, chooser.selected + direction))
            dirty = true
        end
    end
    contacts = taskbar:app_touch(contacts)
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
                launch_app(action.app)
                if not runner:active() then restore_shell(not pending_open) end
                return
            elseif action.confirm_forget then
                confirm_forget = true
            elseif action.forget then
                runner:forget(action.forget.path)
                refresh_task_apps()
                app_menu, confirm_forget = nil, false
            elseif action.cancel_menu then
                app_menu, confirm_forget = nil, false
            elseif action.page then
                page = math.max(1, math.min(page_count(), page + action.page))
            elseif action.refresh then
                message = nil
                scan_apps()
                refresh_task_apps()
            elseif action.dismiss then
                message = nil
            elseif action.candidate then
                chooser.selected = action.candidate
            elseif action.cancel_chooser then
                chooser = nil
            elseif action.open_choice then
                choose_handler(action.open_choice == "always")
                return
            end
            dirty = true
        end
    end
    if dirty then draw() end
end

-- Keep presentation in the OS, after app drawing and any shell overlays.
function update(dt)
    if app_frame then
        gfx.target(300, 180)
        gfx.spr(app_frame, 0, 0)
    end
    update_system(dt)
    if runner:active() then
        if app_frame then
            gfx.flip(app_frame)
            gfx.target()
            gfx.spr(app_frame, 0, 0)
        end
        if message then
            -- Rejection leaves the app alive; show its reason above the app's frame.
            local width = app_frame and desktop_width or gfx.width
            gfx.rectfill(0, 0, width, 16, colors.panel)
            gfx.print(4, 4, shortened(message:gsub("[%c]", " "), math.floor((width - 8) / 6)), colors.error)
        end
    end
    if not runner:active() or app_frame then
        taskbar:draw(task_apps, runner, colors, active_app, battery)
    end
    gfx.flip()
end
