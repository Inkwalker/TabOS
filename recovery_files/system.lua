package.path = "/rec/?.lua;" .. package.path

local boot_error = ...
local commands = {}
local lines = {}
local pending_lines = {}
local pending_first, pending_last = 1, 0
local output_interval = 0.05
local output_elapsed = output_interval
local line = ""
local history = {}
local history_limit = 3
local history_index, history_draft
local current_directory = "/"
local app_update, app_deinit

local row_height = 10
local columns = math.max(1, math.floor((gfx.width - 2) / 6))
local output_rows = math.max(1, math.floor((gfx.height - 2) / row_height) - 2)
local output_history_pages = 3
local view_end -- nil follows the latest output and shows the prompt.

local clock = require("widgets.clock")
local battery = require("widgets.battery")
local paths = require("paths")

local text_color = gfx.rgb(0, 255, 0)
local error_color = gfx.rgb(255, 0, 0)
local panel_color = gfx.rgb(12, 19, 29)

local status_interval = 0.5
local status_elapsed = 0
local caret_interval = 0.5
local caret_elapsed = 0

local function refresh_status()
    local clock_changed = clock.refresh()
    local battery_changed = battery.refresh()
    status_elapsed = 0
    return clock_changed or battery_changed
end

shell = {}

function shell.write(message, color)
    for row in (tostring(message) .. "\n"):gmatch("([^\n]*)\n") do
        for start = 1, math.max(1, #row), columns do
            pending_last = pending_last + 1
            pending_lines[pending_last] = {text = row:sub(start, start + columns - 1), color = color or text_color}
        end
    end
end

local function advance_output(dt)
    output_elapsed = math.min(output_interval, output_elapsed + dt)
    if pending_first > pending_last or output_elapsed < output_interval then
        return false
    end

    -- Reveal at most one row per frame, even after a slow frame.
    lines[#lines + 1] = pending_lines[pending_first]
    pending_lines[pending_first] = nil
    pending_first = pending_first + 1
    if pending_first > pending_last then
        pending_first, pending_last = 1, 0
    end
    if #lines > output_rows * (output_history_pages + 1) then
        table.remove(lines, 1)
        if view_end then
            view_end = math.max(1, view_end - 1)
        end
    end
    output_elapsed = 0
    return true
end

-- Commands receive an array of whitespace-separated arguments.
function shell.register(name, handler, description)
    assert(type(name) == "string" and name:match("^%S+$"), "expected a command name")
    assert(type(handler) == "function", "expected a command handler")
    assert(description == nil or type(description) == "string", "expected a description")
    assert(not commands[name], "command already registered: " .. name)
    commands[name] = {handler = handler, description = description}
end

local function show_error(err)
    shell.write("Error: " .. (type(err) == "string" and err or type(err)), error_color)
end

local function print_to_shell(...)
    local values = table.pack(...)
    for i = 1, values.n do
        values[i] = tostring(values[i])
    end
    shell.write(table.concat(values, "    ", 1, values.n))
end

local function run_script(path, args)
    local env = setmetatable({print = print_to_shell}, {__index = _ENV})
    env._G = env
    local chunk = paths.check(loadfile(path, "t", env))
    local results = table.pack(chunk(table.unpack(args)))
    if results.n > 0 then
        print_to_shell(table.unpack(results, 1, results.n))
    end
end

local function make_app_require(root, env)
    local loaded, loading = {}, {}

    return function(name)
        assert(type(name) == "string" and name:match("^[%w_][%w_.%-]*$")
            and not name:find("..", 1, true) and name:sub(-1) ~= ".",
            "invalid module name")

        if loaded[name] ~= nil then
            return loaded[name]
        end
        if loading[name] then
            error("circular app import: " .. name, 2)
        end

        local base = root .. "/lib/" .. name:gsub("%.", "/")
        local file = base .. ".lua"
        local info = fs.stat(file)
        if not info or info.type ~= "file" then
            file = base .. "/init.lua"
            info = fs.stat(file)
            if not info or info.type ~= "file" then
                error("app module not found: " .. name, 2)
            end
        end

        local chunk = paths.check(loadfile(file, "t", env))
        loading[name] = true
        local ok, result = pcall(chunk, name, file)
        loading[name] = nil

        if not ok then
            error(result, 0)
        end
        if result == nil then
            result = true
        end
        loaded[name] = result
        return result
    end, loaded
end

local function run_app(path, args)
    -- The shell polls input once per frame, including while an app is running.
    local app_input = setmetatable({update = function() end}, {__index = input})
    local env = setmetatable({input = app_input}, {__index = _ENV})
    env._G = env
    local app_require, app_loaded = make_app_require(path, env)
    env.require = app_require
    env.package = {loaded = app_loaded}
    local chunk = paths.check(loadfile(path .. "/app.lua", "t", env))
    chunk(table.unpack(args))

    local start = rawget(env, "init")
    local tick = rawget(env, "update")
    local finish = rawget(env, "deinit")
    if start ~= nil and type(start) ~= "function" then
        error("init must be a function", 0)
    end
    if tick ~= nil and type(tick) ~= "function" then
        error("update must be a function", 0)
    end
    if finish ~= nil and type(finish) ~= "function" then
        error("deinit must be a function", 0)
    end
    if start then
        start()
    end
    app_update, app_deinit = tick, tick and finish
end

local command_directory = "/rec/bin"

-- An external script returns metadata and a handler without running the command.
-- Path handlers receive the working directory followed by resolved operands.
local function load_command(name)
    if not name:match("^[%w_%-]+$") then
        return nil
    end
    local path = command_directory .. "/" .. name .. ".lua"
    local info = fs.stat(path)
    if not info or info.type ~= "file" then
        return nil
    end
    local chunk = paths.check(loadfile(path, "t"))
    local command = chunk()
    assert(type(command) == "table" and type(command.handler) == "function",
        path .. ": expected a command definition")
    assert(command.description == nil or type(command.description) == "string",
        path .. ": expected a description")
    assert(command.operands == nil or (type(command.operands) == "string" and type(command.count) == "number"),
        path .. ": expected operands and an argument count")
    return command
end

shell.register("help", function()
    local names, descriptions = {}, {}
    for name, command in pairs(commands) do
        names[#names + 1] = name
        descriptions[name] = command.description
    end
    for _, entry in ipairs(fs.list(command_directory) or {}) do
        local name = entry:lower():match("^([%w_%-]+)%.lua$")
        if name and not commands[name] then
            local ok, command = pcall(load_command, name)
            if ok and command then
                names[#names + 1] = name
                descriptions[name] = command.description
            end
        end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local description = descriptions[name]
        shell.write(description and (name .. " - " .. description) or name)
    end
    shell.write(".lua - Run a script and print its results.")
    shell.write(".tap - Launch app.lua. Press Esc to exit.")
    shell.write("Quote paths with spaces.")
end, "List commands.")
shell.register("clear", function()
    lines = {}
    view_end = nil
    pending_lines = {}
    pending_first, pending_last = 1, 0
    output_elapsed = output_interval
end, "Clear the screen.")
shell.register("time", function(args)
    local hour, minute = (args[1] or ""):match("^(%d%d):(%d%d)$")
    hour, minute = tonumber(hour), tonumber(minute)
    if #args ~= 1 or not hour or hour > 23 or minute > 59 then
        shell.write("Usage: time HH:MM (24-hour UTC)", error_color)
        return
    end

    if clock.set_time(hour, minute) then
        shell.write("Clock date initialized to 2000-01-01 UTC.")
    end
    refresh_status()
end, "Set the system clock with time HH:MM (UTC).")

shell.register("cd", function(_, path)
    path = path or "/"
    paths.check(paths.path_type(path) == "directory", path .. ": not a directory")
    current_directory = path
end, "Change directory. With no argument, go to /.")
commands.cd.operands, commands.cd.count = "[directory]", 1

local function take_word(rest)
    local quote = rest:sub(1, 1)
    if quote ~= '"' and quote ~= "'" then
        return rest:match("^(%S+)(.*)$")
    end
    local close = rest:find(quote, 2, true)
    if close and close > 2 then
        local remaining = rest:sub(close + 1)
        if remaining == "" or remaining:match("^%s") then
            return rest:sub(2, close - 1), remaining
        end
    end
end

local function parse_paths(rest)
    local args = {}
    while true do
        rest = rest:match("^%s*(.*)$")
        if rest == "" then
            return args
        end
        local path, remaining = take_word(rest)
        if not path then
            return nil
        end
        args[#args + 1] = path
        rest = remaining
    end
end

local file_runners = {[".lua"] = run_script, [".tap"] = run_app}

local function execute(text)
    text = text:match("^%s*(.*)$")
    if text == "" then
        return
    end
    local name, rest = take_word(text)
    if not name then
        show_error("invalid quoted path")
        return
    end
    local extension = name:sub(-4):lower()
    local runner = file_runners[extension]
    if runner then
        local args = parse_paths(rest)
        if not args then
            show_error("invalid quoted path")
            return
        end
        local ok, err = pcall(runner, paths.resolve_path(name, current_directory), args)
        if not ok then
            show_error(err)
        end
        return
    end
    local command = commands[name]
    if not command then
        local ok, external = pcall(load_command, name)
        if not ok then
            show_error(external)
            return
        elseif not external then
            shell.write("Unknown command: " .. name, error_color)
            return
        end
        command = external
    end

    local args
    if command.operands then
        args = parse_paths(rest)
        if not args then
            show_error("invalid quoted path")
            return
        end
        if #args > command.count or (#args ~= command.count and command.operands:sub(1, 1) ~= "[") then
            shell.write("Usage: " .. name .. " " .. command.operands, error_color)
            return
        end
        for i, path in ipairs(args) do
            args[i] = paths.resolve_path(path, current_directory)
        end
    else
        args = {}
        for word in rest:gmatch("%S+") do
            args[#args + 1] = word
        end
    end
    local ok, err
    if command.operands then
        ok, err = pcall(command.handler, current_directory, table.unpack(args))
    else
        ok, err = pcall(command.handler, args)
    end
    if not ok then
        show_error(err)
    end
end

local function prompt_text()
    return current_directory .. "$ " .. line
end

local function navigate_history()
    -- Up and Down are in column 12 of rows 4 and 5 on the Tab5 keyboard.
    -- Ctrl is row 5, column 1; reserve Ctrl+arrows for output pages.
    if input.key(5, 1) then
        local previous_end = view_end
        -- Recompute page boundaries from the latest output after rows arrive.
        local page = view_end and math.max(1, math.floor((#lines - view_end) / output_rows)) or 0
        if input.keyp(4, 12) then
            page = math.min(page + 1, math.floor((#lines - 1) / output_rows))
        elseif input.keyp(5, 12) then
            page = math.max(0, page - 1)
        else
            return false
        end
        view_end = page > 0 and (#lines - page * output_rows) or nil
        return previous_end ~= view_end
    end
    if input.keyp(4, 12) and #history > 0 then
        if not history_index then
            history_draft = line
            history_index = #history + 1
        elseif history_index == 1 then
            return false
        end
        history_index = history_index - 1
        line = history[history_index]
        view_end = nil
        return true
    elseif input.keyp(5, 12) and history_index then
        history_index = history_index + 1
        if history_index > #history then
            line = history_draft
            history_index, history_draft = nil, nil
        else
            line = history[history_index]
        end
        view_end = nil
        return true
    end
    return false
end

local function draw()
    gfx.cls()
    gfx.rectfill(0, 0, gfx.width, 9, panel_color)
    gfx.print(1, 1, view_end and "Recovery Terminal [history]" or "Recovery Terminal", text_color)
    clock.draw(gfx.width - 50, 1, text_color)
    battery.draw(gfx.width - 17, 1, text_color)
    local last = view_end or #lines
    local first = math.max(1, last - output_rows + 1)
    local row_offset = view_end and (output_rows - (last - first + 1)) or 0
    for index = first, last do
        local row = row_offset + index - first + 1
        local entry = lines[index]
        gfx.print(1, 5 + row * row_height, entry.text, entry.color)
    end
    if not view_end then
        local prompt = prompt_text() .. (caret_elapsed < caret_interval and "_" or " ")
        local visible_rows = math.min(#lines, output_rows)
        gfx.print(1, 5 + (visible_rows + 1) * row_height, prompt:sub(-columns), text_color)
    end
    gfx.flip()
end

function init()
    refresh_status()
    shell.write("Type help for commands.")
    if boot_error ~= nil then
        show_error(boot_error)
    end
    advance_output(0)
    draw()
end

function update(dt)
    input.update()
    if app_update then
        -- Esc is row 1, column 1 on the Tab5 keyboard.
        if not input.keyp(1, 1) then
            local ok, err = pcall(app_update, dt)
            if ok then
                return
            end
            show_error(err)
        end
        if app_deinit then
            local ok, err = pcall(app_deinit)
            if not ok then
                show_error(err)
            end
        end
        app_update, app_deinit = nil, nil
        input.txt()
        caret_elapsed = 0
        refresh_status()
        advance_output(0)
        draw()
        return
    end

    status_elapsed = status_elapsed + dt
    local status_changed = status_elapsed >= status_interval and refresh_status()
    local output_changed = advance_output(dt)
    local history_changed = navigate_history()
    local text = input.txt()
    if text == "" then
        local caret_was_visible = caret_elapsed < caret_interval
        caret_elapsed = history_changed and 0 or (caret_elapsed + dt) % (2 * caret_interval)
        local caret_is_visible = caret_elapsed < caret_interval
        if output_changed or history_changed or status_changed or caret_was_visible ~= caret_is_visible then
            draw()
        end
        return
    end
    caret_elapsed = 0
    view_end = nil
    for char in text:gmatch(".") do
        if char == "\n" or char == "\r" then
            shell.write(prompt_text())
            local submitted = line
            line = ""
            history_index, history_draft = nil, nil
            if submitted:match("%S") then
                history[#history + 1] = submitted
                if #history > history_limit then
                    table.remove(history, 1)
                end
            end
            execute(submitted)
            if app_update then
                return
            end
        elseif char == "\b" then
            line = line:sub(1, -2)
        elseif char:match("[ -~]") and #line < 256 then
            line = line .. char
        end
    end
    advance_output(0)
    draw()
end
