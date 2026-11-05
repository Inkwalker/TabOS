package.path = "/recovery/?.lua;" .. package.path

local boot_error = ...
local commands = {}
local lines = {}
local line = ""
local history = {}
local history_limit = 3
local history_index, history_draft
local current_directory = "/"
local app_update, app_deinit

local row_height = 10
local columns = math.max(1, math.floor((gfx.width - 2) / 6))
local output_rows = math.max(1, math.floor((gfx.height - 2) / row_height) - 2)

local clock = require("widgets.clock")
local battery = require("widgets.battery")
local paths = require("paths")

local text_color = gfx.rgb(0, 255, 0)

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

function shell.write(message)
    for row in (tostring(message) .. "\n"):gmatch("([^\n]*)\n") do
        for start = 1, math.max(1, #row), columns do
            lines[#lines + 1] = row:sub(start, start + columns - 1)
            if #lines > output_rows then
                table.remove(lines, 1)
            end
        end
    end
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
    shell.write("Error: " .. (type(err) == "string" and err or type(err)))
end

local function run(args)
    local path = args[1]
    if not path or path == "" then
        shell.write('Usage: run "path[.lua]" [args...]')
        return
    end
    path = paths.resolve_path(path, current_directory)

    -- The shell polls input once per frame, including while an app is running.
    local app_input = setmetatable({update = function() end}, {__index = input})
    local env = setmetatable({input = app_input}, {__index = _ENV})
    env._G = env
    local chunk, err = loadfile(path, "t", env)
    if not chunk and path:sub(-4) ~= ".lua" and err:find("cannot open ", 1, true) == 1 then
        chunk, err = loadfile(path .. ".lua", "t", env)
    end
    if not chunk then
        error(err, 0)
    end
    chunk(table.unpack(args, 2))

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

local command_directory = "/recovery/bin"

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

shell.register("run", run, "Start a Lua file by relative or absolute path. Quote paths with spaces. Esc returns to the shell.")
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
end, "List commands.")
shell.register("clear", function()
    lines = {}
end, "Clear the screen.")
shell.register("time", function(args)
    local hour, minute = (args[1] or ""):match("^(%d%d):(%d%d)$")
    hour, minute = tonumber(hour), tonumber(minute)
    if #args ~= 1 or not hour or hour > 23 or minute > 59 then
        shell.write("Usage: time HH:MM (24-hour UTC)")
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

local function parse_paths(rest)
    local args = {}
    while true do
        rest = rest:match("^%s*(.*)$")
        if rest == "" then
            return args
        end
        local path, remaining
        local quote = rest:sub(1, 1)
        if quote == '"' or quote == "'" then
            local close = rest:find(quote, 2, true)
            if close then
                path, remaining = rest:sub(2, close - 1), rest:sub(close + 1)
            end
            if not path or path == "" or (remaining ~= "" and not remaining:match("^%s")) then
                return nil
            end
        else
            path, remaining = rest:match("^(%S+)(.*)$")
        end
        args[#args + 1] = path
        rest = remaining
    end
end

local function execute(text)
    local name, rest = text:match("^%s*(%S+)(.*)$")
    if not name then
        return
    end
    local command = commands[name]
    if not command then
        local ok, external = pcall(load_command, name)
        if not ok then
            show_error(external)
            return
        elseif not external then
            shell.write("Unknown command: " .. name)
            return
        end
        command = external
    end

    local args
    if command.operands then
        args = parse_paths(rest)
        if not args then
            shell.write("Error: invalid quoted path")
            return
        end
        if #args > command.count or (#args ~= command.count and command.operands:sub(1, 1) ~= "[") then
            shell.write("Usage: " .. name .. " " .. command.operands)
            return
        end
        for i, path in ipairs(args) do
            args[i] = paths.resolve_path(path, current_directory)
        end
    else
        args = {}
        if name == "run" then
            local path, remaining = rest:match('^%s*"([^"]*)"(.*)$')
            if path and (remaining == "" or remaining:match("^%s")) then
                args[1] = path
                rest = remaining
            end
        end
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
    if input.keyp(4, 12) and #history > 0 then
        if not history_index then
            history_draft = line
            history_index = #history + 1
        elseif history_index == 1 then
            return false
        end
        history_index = history_index - 1
        line = history[history_index]
        return true
    elseif input.keyp(5, 12) and history_index then
        history_index = history_index + 1
        if history_index > #history then
            line = history_draft
            history_index, history_draft = nil, nil
        else
            line = history[history_index]
        end
        return true
    end
    return false
end

local function draw()
    gfx.cls()
    gfx.print(1, 1, "Recovery Terminal", text_color)
    clock.draw(gfx.width - 50, 1, text_color)
    battery.draw(gfx.width - 17, 1, text_color)
    for row, text in ipairs(lines) do
        gfx.print(1, 5 + row * row_height, text, text_color)
    end
    local prompt = prompt_text() .. (caret_elapsed < caret_interval and "_" or " ")
    gfx.print(1, 5 + (#lines + 1) * row_height, prompt:sub(-columns), text_color)
    gfx.flip()
end

function init()
    refresh_status()
    shell.write("Type help for commands.")
    if boot_error ~= nil then
        show_error(boot_error)
    end
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
        draw()
        return
    end

    status_elapsed = status_elapsed + dt
    local status_changed = status_elapsed >= status_interval and refresh_status()
    local history_changed = navigate_history()
    local text = input.txt()
    if text == "" then
        local caret_was_visible = caret_elapsed < caret_interval
        caret_elapsed = history_changed and 0 or (caret_elapsed + dt) % (2 * caret_interval)
        local caret_is_visible = caret_elapsed < caret_interval
        if history_changed or status_changed or caret_was_visible ~= caret_is_visible then
            draw()
        end
        return
    end
    caret_elapsed = 0
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
    draw()
end
