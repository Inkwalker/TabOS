local paths = require("paths")
local Gate = require("input_gate")
local Runner = {}
Runner.__index = Runner

local function make_app_require(root, env)
    local loaded, loading = {}, {}
    return function(name)
        assert(type(name) == "string" and name:match("^[%w_][%w_.%-]*$")
            and not name:find("..", 1, true) and name:sub(-1) ~= ".", "invalid module name")
        if loaded[name] ~= nil then return loaded[name] end
        if loading[name] then error("circular app import: " .. name, 2) end
        local base = root .. "/lib/" .. name:gsub("%.", "/")
        local file = base .. ".lua"
        local info = fs.stat(file)
        if not info or info.type ~= "file" then
            file = base .. "/init.lua"
            info = fs.stat(file)
            if not info or info.type ~= "file" then error("app module not found: " .. name, 2) end
        end
        local chunk = paths.check(loadfile(file, "t", env))
        loading[name] = true
        local ok, result = pcall(chunk, name, file)
        loading[name] = nil
        if not ok then error(result, 0) end
        if result == nil then result = true end
        loaded[name] = result
        return result
    end, loaded
end

function Runner.new(raw_input, report)
    return setmetatable({input = raw_input, report = report, launches = 0, sessions = {}}, Runner)
end

local function session_key(path)
    return paths.resolve_path(path, "/"):lower()
end

function Runner:session(path)
    return self.sessions[session_key(path)]
end

function Runner:has_session(path)
    return self:session(path) ~= nil
end

function Runner:forget(path)
    local key = session_key(path)
    local existed = self.sessions[key] ~= nil
    self.sessions[key] = nil
    collectgarbage("collect")
    return existed
end

-- Shells can request the same deferred transition as the app's os.suspend().
function Runner:suspend()
    if self.app then self.app.suspend_requested = true end
end

function Runner:active()
    return self.app ~= nil
end

function Runner:finish(reason)
    local app = self.app
    if not app then return end
    self.app = nil -- Cleanup and stale app requests cannot affect another app.
    local cleanup = app.env and rawget(app.env, "deinit")
    if type(cleanup) == "function" then
        local ok, err = pcall(cleanup, reason)
        if not ok then self.report(err) end
    end
    audio.stop() -- Includes queued playback; the native stop-all cannot lose to a full queue.
    self.input.txt()
    cleanup = nil
    app.env, app.input, app.args = nil, nil, nil
    collectgarbage("collect")
end

function Runner:transition()
    local app = self.app
    if app.exit_requested then
        self:finish("exit")
    elseif app.suspend_requested then
        app.suspend_requested = nil
        local ok, err = pcall(function()
            local save = rawget(app.env, "save_state")
            local state, message
            if save then state, message = save() end
            if app.exit_requested then return end
            if state == nil and message ~= nil then error(message, 0) end
            assert(state == nil or (type(state) == "table" and getmetatable(state) == nil),
                "save_state must return a plain table or nil")
            self.sessions[session_key(app.path)] = {state = state, args = app.args}
        end)
        -- Requests made from save_state belong to this attempt, not the next frame.
        app.suspend_requested = nil
        if app.exit_requested then
            if not ok then self.report(err) end
            self:finish("exit")
        elseif ok then
            self:finish("suspend")
        else
            self.report(err)
        end
    elseif not rawget(app.env, "update") then
        self:finish("exit")
    end
end

function Runner:launch(path, args)
    assert(not self.app, "an app is already running")
    path = paths.resolve_path(path, "/")
    local key = session_key(path)
    local saved = self.sessions[key]
    if not args or #args == 0 then args = saved and saved.args or {} end
    args = {table.unpack(args)}
    self.launches = self.launches + 1
    local app = {path = path, args = args}
    self.app = app
    local ok, err = pcall(function()
        app.input = Gate.new(self.input)
        ---@diagnostic disable-next-line: duplicate-set-field
        app.input.update = function() end -- Hardware is polled once by the shell.
        local env = setmetatable({input = app.input, os = {
            exit = function() app.exit_requested = true end,
            suspend = function() app.suspend_requested = true end,
            path = function(relative_path)
                assert(type(relative_path) == "string", "expected a path string")
                return paths.resolve_path(relative_path, path)
            end,
        }}, {__index = _ENV})
        app.env, env._G = env, env
        local app_require, app_loaded = make_app_require(path, env)
        env.require = app_require
        env.package = {loaded = app_loaded}
        local chunk = paths.check(loadfile(path .. "/app.lua", "t", env))
        chunk(table.unpack(args))
        for _, name in ipairs({"init", "update", "deinit", "save_state"}) do
            local hook = rawget(env, name)
            assert(hook == nil or type(hook) == "function", name .. " must be a function")
        end
        if app.exit_requested or app.suspend_requested then return end
        local start = rawget(env, "init")
        if start then start(saved and saved.state) end
        app.initialized = true
    end)
    if not ok then
        self.report(err)
        self:finish("error")
        return nil, err
    end
    -- A top-level exit/suspend skips init and has not consumed the incoming state.
    if app.initialized then self.sessions[key] = nil end
    saved, args = nil, nil
    self:transition()
    return true
end

function Runner:update(dt)
    local app = self.app
    if not app then return end
    -- Reserved system chord uses raw input, even when app input is gated.
    if self.input.key(5, 1) and self.input.keyp(1, 1) then
        self:finish("forced")
        return
    end
    app.input.refresh()
    local callback = rawget(app.env, "update")
    -- A rejected suspension can leave even an app without update active for retry.
    if not callback then
        if app.exit_requested or app.suspend_requested then self:transition() end
        return
    end
    local ok, err = pcall(callback, dt)
    callback = nil -- Do not retain an environment through its hook during cleanup/GC.
    if not ok then
        self.report(err)
        self:finish("error")
    else
        self:transition()
    end
end

return Runner
