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
local desktop
local message
local message_age = 0
local status_elapsed = 0
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

local function load_shortcuts()
    local paths, err, code = fs.read_table(shortcuts_path)
    if not paths and code ~= 2 then
        if not message then show_error(err or ("Cannot read " .. shortcuts_path)) end
        return
    end
    taskbar:clear_icons()
    shortcuts = {}
    local seen = {}
    for _, path in ipairs(paths or {}) do
        local app = Registry.bundle(path)
        local key = app and fs.fat_name_key(app.path)
        if key and not seen[key] then
            seen[key] = true
            shortcuts[#shortcuts + 1] = launcher_entry(app)
        end
    end
end

local function shortened(text, limit)
    if #text <= limit then return text end
    return text:sub(1, math.max(0, limit - 3)) .. "..."
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

local function release_desktop()
    if not desktop then return end
    desktop:close()
    desktop = nil
    -- Reclaim the module and view before allocating the app frame or running app code.
    package.loaded.desktop = nil
    collectgarbage("collect")
end

local function launch_app(app, args)
    release_app_frame()
    if not app.window then taskbar:clear_icons() end
    release_desktop()
    message = nil
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

local function restore_shell(refresh_shortcuts)
    release_app_frame()
    if gfx.width ~= 320 or gfx.height ~= 180 then gfx.target() end
    input.reset()
    if refresh_shortcuts then load_shortcuts() end
    if not desktop then
        desktop = require("desktop").new(shortcuts, config, colors, runner)
    end
    desktop:reset_contact(true)
    desktop:close_menu()
    refresh_task_apps()
    refresh_status()
    desktop:draw(chooser, message)
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
    if idle.update(dt, runner:active()) and desktop then
        desktop:reset_contact(true)
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
            desktop:close_menu()
            dirty = true
        elseif selected and selected ~= Taskbar.HOME then
            launch_app(selected)
            if not runner:active() then restore_shell(not pending_open) end
            return
        end
    end
    if chooser and not message then
        if input.keyp(1, 1) then
            chooser = nil
            desktop:reset_contact(#contacts > 0)
            desktop:draw(chooser, message)
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
    local action, touched = desktop:update_touch(taskbar:app_touch(contacts), dt)
    if action then
        if action.app then
            -- Launch on release so the app cannot inherit the launcher tap.
            launch_app(action.app)
            if not runner:active() then restore_shell(not pending_open) end
            return
        elseif action.forget then
            runner:forget(action.forget.path)
            refresh_task_apps()
            desktop:close_menu()
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
    end
    if dirty or touched then desktop:draw(chooser, message) end
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
            local width = app_frame and app_frame.width or gfx.width
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
