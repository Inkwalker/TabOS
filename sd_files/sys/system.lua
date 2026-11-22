-- Keep the recovery lifecycle implementation shared by both shells.
package.path = package.path .. ";/rec/sys/?.lua"
local raw_input = input
local Gate = require("input_gate")
local input = Gate.new(raw_input)
local config = fs.read_table("/sd/sys/config.ltab") or {}
local idle = require("idle").new(raw_input, input, config)
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
local file_dialog, pending_file_dialog
local Registry = require("associations")
local associations = Registry.new(config.files_app)
local Taskbar = require("taskbar")
local taskbar = Taskbar.new()
local desktop_width = 300
local shortcuts_path = "/sd/sys/shortcuts.ltab"
local wallpaper_path = config.wallpaper
local wallpaper
if type(wallpaper_path) == "string" and wallpaper_path ~= "" and not wallpaper_path:find("%z") then
    wallpaper = gfx.load_sprite(wallpaper_path)
end

local colors = {
    background = gfx.rgb(19, 33, 49),
    panel = gfx.rgb(12, 19, 29),
    tile = gfx.rgb(25, 37, 54),
    pressed = gfx.rgb(43, 64, 88),
    accent = gfx.rgb(108, 205, 255),
    text = gfx.rgb(235, 242, 250),
    muted = gfx.rgb(155, 174, 195),
    error = gfx.rgb(255, 92, 97),
    home_sprite_key = gfx.rgb(255, 0, 255),
}

local function valid_channel(value)
    return type(value) == "number" and value >= 0 and value <= 255 and value % 1 == 0
end

for name, rgb in pairs(fs.read_table("/sd/sys/theme.ltab") or {}) do
    if type(rgb) == "table" and valid_channel(rgb[1]) and valid_channel(rgb[2]) and valid_channel(rgb[3]) then
        colors[name] = gfx.rgb(rgb[1], rgb[2], rgb[3])
    end
end

local margin = 8
local cell_width, cell_height = 70, 54
local columns = math.floor((desktop_width - margin * 2) / cell_width)
local rows = math.floor((gfx.height - margin * 2) / cell_height)
local desktop_slots = columns * rows
local per_page = desktop_slots

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
    file_dialog = function(request) pending_file_dialog = request end,
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
        if path == active_key or runner:has_session(app.path) then
            if not known[path] then extra[#extra + 1] = app end
        else
            opened_apps[path] = nil
        end
    end
    table.sort(extra, function(a, b) return a.path < b.path end)
    for _, app in ipairs(extra) do task_apps[#task_apps + 1] = app end
end

local function refresh_status()
    local battery_changed, level, charging = battery.refresh()
    battery_monitor.update(level, charging, config.auto_shutdown)
    status_elapsed = 0
    return battery_changed
end

local function page_count()
    return math.max(1, math.ceil(#apps / per_page))
end

local function load_shortcuts()
    local paths, err, code = fs.read_table(shortcuts_path)
    if not paths and code ~= 2 then
        if not message then show_error(err or ("Cannot read " .. shortcuts_path)) end
        return
    end
    for _, app in ipairs(apps) do
        if app.icon then app.icon:close() end
    end
    apps = {}
    local seen = {}
    for _, path in ipairs(paths or {}) do
        local app = Registry.bundle(path)
        local key = app and fs.fat_name_key(app.path)
        if key and not seen[key] then
            seen[key] = true
            if app.icon_path then
                app.icon = gfx.load_sprite(app.icon_path)
                if app.icon and (app.icon.width > 28 or app.icon.height > 28) then
                    app.icon:close()
                    app.icon = nil
                end
            end
            apps[#apps + 1] = app
        end
    end
    -- Leave the last cell free for navigation only when the desktop overflows.
    per_page = #apps > desktop_slots and desktop_slots - 1 or desktop_slots
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
    if wallpaper then gfx.spr(wallpaper, 0, 0) end
    local first = (page - 1) * per_page + 1
    for index = first, math.min(#apps, first + per_page - 1) do
        local app = apps[index]
        local slot = index - first
        local x = margin + math.floor(slot / rows) * cell_width
        local y = margin + (slot % rows) * cell_height
        local width, height = cell_width - 4, cell_height - 4
        target(x, y, width, height, {app = app})
        local held = pressed and pressed.action.app == app
        if held then gfx.rectfill(x, y, width, height, colors.pressed) end
        local icon_x = x + math.floor((width - 28) / 2)
        if app.icon then
            gfx.spr(app.icon, icon_x + math.floor((28 - app.icon.width) / 2),
                y + 6 + math.floor((28 - app.icon.height) / 2))
        else
            gfx.rectfill(icon_x, y + 6, 28, 28, colors.accent)
            centered(icon_x, y + 16, 28, app.name:sub(1, 1):upper(), colors.background)
        end
        local label = shortened(app.name, math.floor((width - 4) / 6))
        centered(x, y + 42, width, label, colors.text)
    end
    if #apps == 0 then
        centered(0, 74, desktop_width, "No desktop shortcuts", colors.muted)
        centered(0, 88, desktop_width, "Add apps to " .. shortcuts_path, colors.muted)
    end

    local pages = page_count()
    if pages > 1 then
        local x = margin + (columns - 1) * cell_width
        local y = margin + rows * cell_height - 24
        local function page_button(left, label, direction)
            local enabled = page + direction >= 1 and page + direction <= pages
            if enabled then target(left, y, 20, 20, {page = direction}) end
            gfx.rectfill(left, y, 20, 20, colors.panel)
            centered(left, y + 6, 20, label, enabled and colors.text or colors.muted)
        end
        page_button(x, "<", -1)
        centered(x + 20, y + 6, 30, page .. "/" .. pages, colors.muted)
        page_button(x + 50, ">", 1)
    end

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
    pending_file_dialog = nil
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

local function restore_shell(refresh_shortcuts)
    release_app_frame()
    input.reset()
    touch_held, pressed = true, nil
    app_menu, confirm_forget = nil, false
    if refresh_shortcuts then load_shortcuts() end
    refresh_task_apps()
    refresh_status()
    draw()
end

function init()
    associations:refresh()
    restore_shell(true)
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

local function finish_file_dialog(path, err)
    local dialog = file_dialog
    file_dialog = nil
    if dialog.picker then
        local ok, detail = pcall(dialog.picker.close, dialog.picker)
        if not ok then path, err = nil, err or tostring(detail) end
    end
    local frame = dialog.frame
    if frame then
        gfx.target(frame.width, frame.height)
        gfx.spr(frame, 0, 0)
        frame:close()
    end
    input.reset()
    runner:complete_file_dialog(dialog.callback, path, err)
end

local function start_file_dialog(request)
    local dialog = {callback = request.callback, input = Gate.new(app_input)}
    file_dialog = dialog
    local ok, picker = pcall(function()
        if not app_frame then
            local frame = assert(gfx.create_sprite(gfx.width, gfx.height))
            local captured, err = pcall(gfx.flip, frame)
            if not captured then
                frame:close()
                error(err, 0)
            end
            dialog.frame = frame
        end
        return require("file_dialog")(config, request.options, {
            input = dialog.input, colors = colors, width = gfx.width, height = gfx.height,
        })
    end)
    if ok then dialog.picker = picker else finish_file_dialog(nil, tostring(picker)) end
end

local function update_file_dialog(dt, switch_to)
    local dialog = file_dialog
    dialog.input.refresh()
    if switch_to or dialog.input.keyp(1, 1) then
        finish_file_dialog()
    elseif dialog.error then
        finish_file_dialog(nil, dialog.error)
    else
        local ok, done, path, err = pcall(dialog.picker.update, dialog.picker, dt)
        if not ok then
            finish_file_dialog(nil, tostring(done))
        elseif done then
            if path ~= nil and (type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("[%c\\]")) then
                path, err = nil, "The file picker returned an invalid path"
            end
            if err ~= nil then path, err = nil, tostring(err) end
            finish_file_dialog(path, err)
        end
    end
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
        local switch_to, forget
        if app_frame then switch_to, forget = taskbar:route(input.touch(), dt) end
        local previous = active_app
        if forget then
            runner:forget(forget.path)
            refresh_task_apps()
        elseif switch_to then
            message = nil
            runner:suspend()
        end
        local request = pending_file_dialog
        pending_file_dialog = nil
        if file_dialog or request then
            if file_dialog then
                update_file_dialog(dt, switch_to)
            elseif switch_to then
                runner:complete_file_dialog(request.callback)
            else
                start_file_dialog(request)
            end
        else
            runner:update(dt)
        end
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
    local selected, forget = taskbar:route(contacts, dt)
    if not chooser and not message then
        if forget then
            runner:forget(forget.path)
            refresh_task_apps()
            app_menu, confirm_forget = nil, false
            dirty = true
        elseif selected and selected ~= Taskbar.HOME then
            app_menu, confirm_forget = nil, false
            launch_app(selected)
            if not runner:active() then restore_shell(not pending_open) end
            return
        end
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
        if file_dialog then
            local frame = file_dialog.frame
            if frame then
                gfx.target()
                gfx.spr(frame, 0, 0)
            end
            local ok, err = pcall(file_dialog.picker.draw, file_dialog.picker)
            if not ok then file_dialog.error = tostring(err) end
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
    collectgarbage("step")
end
