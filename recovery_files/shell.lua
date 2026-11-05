local commands = {}
local lines = {}
local line = ""
local app_update, app_deinit

local row_height = 10
local columns = math.max(1, math.floor((gfx.width - 2) / 6))
local output_rows = math.max(1, math.floor((gfx.height - 2) / row_height) - 2)

local status_interval = 0.5
local seconds_per_day = 86400
local rtc_min_timestamp = 946684800 -- 2000-01-01 00:00 UTC
local status_elapsed = 0
local time_label
local battery_level, battery_charging

local function refresh_status()
    local minutes = math.floor((sys.get_time() % seconds_per_day) / 60)
    local time = string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
    local level = sys.bat_lvl()
    level = level and math.min(100, math.max(0, level))
    local charging = sys.bat_chrg()

    local changed = time ~= time_label or level ~= battery_level or charging ~= battery_charging
    time_label, battery_level, battery_charging = time, level, charging
    status_elapsed = 0
    return changed
end

local text_color = gfx.rgb(0, 255, 0)
local battery_colors = {
    background = gfx.rgb(12, 19, 29),
    track = gfx.rgb(37, 49, 64),
    outline = text_color,
    normal = gfx.rgb(64, 218, 146),
    low = gfx.rgb(255, 183, 62),
    critical = gfx.rgb(255, 92, 97),
    charging = gfx.rgb(108, 205, 255),
}

local function draw_battery()
    local x, y = gfx.width - 17, 1
    local body_width, body_height = 16, 8
    local colors = battery_colors

    gfx.rectfill(x + 1, y + 1, body_width - 1, body_height - 1, colors.background)
    gfx.rect(x, y, body_width, body_height, colors.outline)
    gfx.rectfill(x - 1, y + 2, 1, 4, colors.outline)
    gfx.rectfill(x + 2, y + 2, body_width - 4, body_height - 4, colors.track)

    if battery_level == nil then
        gfx.line(x + 2, y + 4, x + body_width - 2, y + 4, colors.outline)
    elseif battery_level > 0 then
        local fill_width = math.ceil((body_width - 4) * battery_level / 100)
        local fill = colors.normal
        if battery_level <= 10 then
            fill = colors.critical
        elseif battery_level <= 25 then
            fill = colors.low
        end
        if battery_charging then
            fill = colors.charging
        end
        gfx.rectfill(x + 2, y + 2, fill_width, body_height - 4, fill)
    end
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
    if not path or path:sub(1, 1) ~= "/" then
        shell.write('Usage: run "/absolute/path[.lua]" [args...]')
        return
    end

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

shell.register("run", run, "Start a Lua file by absolute path. Quote paths with spaces. Esc returns to the shell.")
shell.register("help", function()
    local names = {}
    for name in pairs(commands) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local description = commands[name].description
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

    local now = sys.get_time()
    local midnight = math.max(rtc_min_timestamp, now - now % seconds_per_day)
    sys.set_time(midnight + hour * 3600 + minute * 60)
    if now < rtc_min_timestamp then
        shell.write("Clock date initialized to 2000-01-01 UTC.")
    end
    refresh_status()
end, "Set the system clock with time HH:MM (UTC).")

local function execute(text)
    local name, rest = text:match("^%s*(%S+)(.*)$")
    if not name then
        return
    end
    local command = commands[name]
    if not command then
        shell.write("Unknown command: " .. name)
        return
    end

    local args = {}
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
    local ok, err = pcall(command.handler, args)
    if not ok then
        show_error(err)
    end
end

local function draw()
    gfx.cls()
    gfx.print(1, 1, "Tab5 Lua", text_color)
    gfx.print(gfx.width - 50, 1, time_label, battery_colors.outline)
    draw_battery()
    for row, text in ipairs(lines) do
        gfx.print(1, 5 + row * row_height, text, text_color)
    end
    local prompt = "> " .. line .. "_"
    gfx.print(1, 5 + (#lines + 1) * row_height, prompt:sub(-columns), text_color)
    gfx.flip()
end

function init()
    refresh_status()
    shell.write("Recovery shell. Type help for commands.")
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
        refresh_status()
        draw()
        return
    end

    status_elapsed = status_elapsed + dt
    local status_changed = status_elapsed >= status_interval and refresh_status()
    local text = input.txt()
    if text == "" then
        if status_changed then
            draw()
        end
        return
    end
    for char in text:gmatch(".") do
        if char == "\n" or char == "\r" then
            shell.write("> " .. line)
            local submitted = line
            line = ""
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
