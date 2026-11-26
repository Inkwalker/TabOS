-- Keep the recovery lifecycle implementation shared by both shells.
package.path = package.path .. ";/rec/sys/?.lua"
local raw_input = input
local Gate = require("input_gate")
local input = Gate.new(raw_input)
local config = fs.read_table("/sd/sys/config.ltab") or {}
local idle = require("idle").new(raw_input, input, config)
local battery = require("widgets.battery")
local battery_monitor = require("battery_monitor")
-- Shortcut metadata also determines taskbar order while the desktop is unloaded.
local shortcuts = {}
local desktop, launcher_touch, launcher_surface, launcher_dialog
local dialogs = require("lib.dialog_manager").new()
local notification
local notification_age = 0
local status_elapsed = 0
local app_frame
local active_app
local opened_apps = {}
local task_apps = {}
local pending_open
local Registry = require("associations")
local resolve_path = require("paths").resolve_path
local associations = Registry.new(config.files_app)
local Taskbar = require("taskbar")
local taskbar = Taskbar.new()
local shortcuts_path = "/sd/sys/shortcuts.ltab"

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

local function open_message(text)
    dialogs:push(require("lib.dialogs.message").new(text, colors), "launcher")
end

local runner
local function show_error(err)
    if runner and runner:active() then
        notification = tostring(err)
        notification_age = 0
    else
        open_message(tostring(err))
    end
end

local app_input = setmetatable({touch = function()
    local contacts = raw_input.touch()
    return app_frame and taskbar:app_touch(contacts) or contacts
end}, {__index = raw_input})
runner = require("app_runner").new(app_input, show_error, {
    open = function(request) pending_open = request end,
    refresh = function() return associations:refresh() end,
    file_dialog = function(request)
        taskbar:reset()
        local picker = require("lib.dialogs.file_dialog").new(config, request, {
            input = app_input, colors = colors, capture = not app_frame,
        })
        dialogs:push(picker, "app")
    end,
})

local function refresh_task_apps()
    local known, extra = {}, {}
    local active_key = active_app and fs.fat_name_key(active_app.path)
    task_apps = {}
    for _, app in ipairs(shortcuts) do
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

local function launcher_entry(app)
    return {path = app.path, name = app.name, window = app.window,
        icon_path = app.icon_path, icon_key = app.icon_key}
end

local function shortcut_entries(paths)
    local apps = {}
    local seen = {}
    for _, path in ipairs(paths) do
        local app = Registry.bundle(path)
        local key = app and fs.fat_name_key(app.path)
        if key and not seen[key] then
            seen[key] = true
            apps[#apps + 1] = launcher_entry(app)
        end
    end
    return apps
end

local function set_shortcuts(apps)
    taskbar:clear_icons()
    shortcuts = apps
end

local function load_shortcuts()
    local paths, err, code = fs.read_table(shortcuts_path)
    if not paths and code ~= 2 then
        local text = err or ("Cannot read " .. shortcuts_path)
        local dialog = dialogs:top("launcher")
        if not dialog or dialog.text ~= text then show_error(text) end
        return
    end
    set_shortcuts(shortcut_entries(paths or {}))
end

local function shortcut_key(path)
    if type(path) == "string" and path:sub(1, 1) == "/" and not path:find("[%c\\]") then
        return fs.fat_name_key(resolve_path(path, "/"))
    end
end

local function edit_shortcut(app, adding)
    local paths, err, code = fs.read_table(shortcuts_path)
    if not paths and code ~= 2 then
        show_error(err or ("Cannot read " .. shortcuts_path))
        return
    end

    local updated = {}
    for key, path in pairs(paths or {}) do updated[key] = path end
    local app_key = fs.fat_name_key(app.path)
    local found = false
    for index = #updated, 1, -1 do
        if shortcut_key(updated[index]) == app_key then
            found = true
            if not adding then table.remove(updated, index) end
        end
    end
    local entries = shortcut_entries(updated)
    if adding and not found then
        local candidate = Registry.bundle(app.path)
        if not candidate then
            show_error("App is unavailable: " .. app.path)
            return
        end
        if #entries >= desktop.shortcuts.capacity then
            show_error("Desktop is full. Remove a shortcut first.")
            return
        end
        updated[#updated + 1] = candidate.path
        entries[#entries + 1] = launcher_entry(candidate)
    end
    local warning
    if adding ~= found then
        local ok
        ok, warning = fs.write_table(shortcuts_path, updated)
        if not ok then
            show_error(warning or ("Cannot write " .. shortcuts_path))
            return
        end
    end

    if not adding and runner:has_session(app.path) then opened_apps[app_key] = app end
    dialogs:pop("launcher")
    if adding then dialogs:pop("launcher") end
    set_shortcuts(entries)
    desktop:set_shortcuts(shortcuts)
    refresh_task_apps()
    if warning then show_error(warning) end
end

local function open_shortcut_picker()
    local installed, err, code = fs.list("/sd/apps")
    if not installed and code ~= 2 then
        show_error(err or "Cannot read /sd/apps")
        return
    end

    local seen, candidates = {}, {}
    for _, app in ipairs(shortcuts) do seen[fs.fat_name_key(app.path)] = true end
    for _, item in ipairs(installed or {}) do
        if item.type ~= "file" and item.name:sub(-4):lower() == ".tap" then
            local app = Registry.bundle("/sd/apps/" .. item.name)
            local key = app and fs.fat_name_key(app.path)
            if key and not seen[key] then
                seen[key] = true
                candidates[#candidates + 1] = app
            end
        end
    end
    table.sort(candidates, function(a, b)
        local left, right = a.name:lower(), b.name:lower()
        if left == right then return a.path < b.path end
        return left < right
    end)
    local picker = require("lib.dialogs.shortcut_picker").new(candidates, colors)
    dialogs:push(picker, "launcher")
end

local function shortened(text, limit)
    if #text <= limit then return text end
    return text:sub(1, math.max(0, limit - 3)) .. "..."
end

local function release_app_frame()
    while dialogs:top("app") do
        local dialog = dialogs:pop("app")
        if dialog.close then dialog:close() end
    end
    if app_frame then
        gfx.target()
        app_frame:close()
        app_frame = nil
    end
    active_app = nil
    taskbar:reset()
end

local function release_desktop()
    if not desktop then return end
    desktop:close()
    launcher_touch:reset(true)
    desktop, launcher_touch, launcher_surface, launcher_dialog = nil, nil, nil, nil
    -- Reclaim the module and view before allocating the app frame or running app code.
    package.loaded.desktop = nil
    package.loaded["lib.shortcut_view"] = nil
    package.loaded["lib.launcher_touch"] = nil
    if not dialogs:top("launcher") then
        for _, name in ipairs({"app_menu", "session_confirmation", "open_with", "message", "desktop_customization",
            "shortcut_picker"}) do
            package.loaded["lib.dialogs." .. name] = nil
        end
    end
    collectgarbage("collect")
end

local function launch_app(app, args)
    release_app_frame()
    if not app.window then taskbar:clear_icons() end
    release_desktop()
    notification = nil
    local ok, err = pcall(function()
        if app.window then
            app_frame = assert(gfx.create_sprite(300, 180))
            gfx.target(300, 180)
        end
        active_app = app
        opened_apps[fs.fat_name_key(app.path)] = launcher_entry(app)
        runner:launch(app.path, args)
    end)
    input.reset()
    refresh_task_apps()
    if not ok then show_error(err) end
end

local function draw_taskbar()
    taskbar:draw(task_apps, runner, colors, active_app, battery)
end

local function draw_launcher()
    local dialog = dialogs:top("launcher")
    if dialog ~= launcher_dialog then
        local held = #input.touch() > 0
        launcher_touch:reset(held)
        taskbar:reset(held)
        launcher_dialog = dialog
    end
    local pressed = launcher_touch.pressed
    local shortcut_targets = desktop:draw(pressed and pressed.action.app)
    if dialog then
        draw_taskbar()
        launcher_surface = dialogs:draw("launcher") or {}
    else
        launcher_surface = shortcut_targets
    end
end

local function restore_shell(refresh_shortcuts)
    release_app_frame()
    if gfx.width ~= 320 or gfx.height ~= 180 then gfx.target() end
    input.reset()
    if notification then
        open_message(notification)
        notification = nil
    end
    if refresh_shortcuts then load_shortcuts() end
    if not desktop then
        desktop = require("desktop").new(shortcuts, config, colors)
        launcher_touch = require("lib.launcher_touch").new()
    end
    launcher_touch:reset(true)
    refresh_task_apps()
    refresh_status()
    draw_launcher()
end

function init()
    associations:refresh()
    restore_shell(true)
end

local function open_result(result, err)
    if result and result.app then
        launch_app(result.app, result.args)
        if result.warning and not notification then show_error(result.warning) end
    elseif result then
        dialogs:push(require("lib.dialogs.open_with").new(result, colors), "launcher")
    else
        show_error(err)
    end
end

local function process_open()
    local request = pending_open
    pending_open = nil
    notification = nil
    open_result(associations:resolve(request))
end

local function choose_handler(dialog, always)
    local request = dialog.request
    dialogs:pop("launcher")
    open_result(associations:choose(request.path, request.extension,
        request.candidates[dialog.selected], always))
    if not runner:active() then restore_shell() end
end

local function update_file_dialog(dialog, dt)
    local done, path, err = dialog:update(dt)
    if done then
        dialogs:pop("app")
        path, err = dialog:close(path, err)
        taskbar:reset()
        input.reset()
        runner:complete_file_dialog(dialog.callback, path, err)
    end
end

local function open_session_confirmation(app, operation, scope, parent)
    local confirmation = require("lib.dialogs.session_confirmation").new(app, colors, operation, parent)
    dialogs:push(confirmation, scope)
end

local function forget_session(dialog, scope, app)
    runner:forget(app.path)
    refresh_task_apps()
    dialogs:pop(scope)
    if dialog.parent and dialogs:top(scope) == dialog.parent then dialogs:pop(scope) end
end

local function update_app_dialog(dialog, dt)
    if not dialog.poll then
        update_file_dialog(dialog, dt)
        return
    end
    local action = dialog:poll(input, dt)
    if not action then return end
    if action.forget then
        forget_session(dialog, "app", action.forget)
    else
        dialogs:pop("app")
    end
    taskbar:reset()
    input.reset()
    if action.suspend then
        notification = nil
        runner:suspend()
        runner:update(dt)
    end
end

local function update_system(dt)
    input.update()
    if idle.update(dt, runner:active()) and launcher_touch then
        launcher_touch:reset(true)
    end
    status_elapsed = status_elapsed + dt
    local dirty = status_elapsed >= 0.5 and refresh_status()
    if pending_open and not runner:active() then
        process_open()
        if not runner:active() then restore_shell() end
        return
    elseif runner:active() then
        notification_age = notification_age + dt
        if notification_age >= 4 then notification = nil end
        local previous = active_app
        local switch_to
        local dialog = dialogs:top("app")
        if dialog then
            update_app_dialog(dialog, dt)
        else
            local held_app, held_active
            if app_frame then switch_to, held_app, held_active = taskbar:route(input.touch(), dt) end
            if held_app then
                open_session_confirmation(held_app, held_active and "suspend" or "forget", "app")
                taskbar:reset()
                input.reset()
                return
            end
            if switch_to then
                notification = nil
                runner:suspend()
            end
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
    local dialog = dialogs:top("launcher")
    if dialog ~= launcher_dialog then draw_launcher() end
    if not dialog then
        local selected, held_app = taskbar:route(contacts, dt)
        if held_app then
            open_session_confirmation(held_app, "forget", "launcher")
            draw_launcher()
            return
        elseif selected and selected ~= Taskbar.HOME then
            launch_app(selected)
            if not runner:active() then restore_shell(not pending_open) end
            return
        end
    end
    local action = dialog and dialog.key_action and dialog:key_action(input)
    if action and action.candidate then
        dialog.selected = action.candidate
        action = nil
        dirty = true
    end
    local touched, held
    if action then
        launcher_touch:reset(#contacts > 0)
        touched = true
    else
        action, touched, held = launcher_touch:update(launcher_surface, taskbar:app_touch(contacts), dt)
    end
    if action then
        if held then
            local menu
            if action.customize_desktop then
                menu = require("lib.dialogs.desktop_customization").new(colors)
            else
                menu = require("lib.dialogs.app_menu").new(action.app, runner, colors)
            end
            dialogs:push(menu, "launcher")
        elseif action.app then
            -- Launch on release so the app cannot inherit the launcher tap.
            if dialog then dialogs:pop("launcher") end
            launch_app(action.app)
            if not runner:active() then restore_shell(not pending_open) end
            return
        elseif action.forget then
            forget_session(dialog, "launcher", action.forget)
        elseif action.confirm_forget then
            open_session_confirmation(dialog.app, "forget", "launcher", dialog)
        elseif action.remove_shortcut then
            edit_shortcut(action.remove_shortcut, false)
        elseif action.open_shortcut_picker then
            open_shortcut_picker()
        elseif action.add_shortcut then
            edit_shortcut(action.add_shortcut, true)
        elseif action.shortcut_page then
            dialog.page = action.shortcut_page
        elseif action.cancel_menu or action.dismiss or action.cancel_chooser then
            dialogs:pop("launcher")
        elseif action.candidate then
            dialog.selected = action.candidate
        elseif action.open_choice then
            choose_handler(dialog, action.open_choice == "always")
            return
        end
    end
    if dirty or touched then draw_launcher() end
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
        local dialog = dialogs:top("app")
        local show_dialog = dialog and (not dialog.draw_background or dialog:draw_background())
        if app_frame then draw_taskbar() end
        if show_dialog then dialogs:draw("app") end
        if notification then
            -- Rejection leaves the app alive; show its reason above the app's frame.
            local width = app_frame and app_frame.width or gfx.width
            gfx.rectfill(0, 0, width, 16, colors.panel)
            gfx.print(4, 4, shortened(notification:gsub("[%c]", " "), math.floor((width - 8) / 6)), colors.error)
        end
    elseif not dialogs:top("launcher") then
        draw_taskbar()
    end
    gfx.flip()
    collectgarbage("step")
end
