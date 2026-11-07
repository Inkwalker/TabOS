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
    return setmetatable({input = raw_input, report = report, launches = 0}, Runner)
end

function Runner:active()
    return self.app ~= nil
end

function Runner:finish(reason)
    local app = self.app
    if not app then return end
    self.app = nil -- Cleanup and old os.exit references cannot affect another app.
    local cleanup = rawget(app.env, "deinit")
    if type(cleanup) == "function" then
        local ok, err = pcall(cleanup, reason)
        if not ok then self.report(err) end
    end
    self.input.txt()
end

function Runner:launch(path, args)
    assert(not self.app, "an app is already running")
    self.launches = self.launches + 1
    local app = {input = Gate.new(self.input)}
    app.input.update = function() end -- Hardware is polled once by the shell.
    local env = setmetatable({input = app.input, os = {exit = function()
        app.exit_requested = true
    end}}, {__index = _ENV})
    app.env, env._G = env, env
    local app_require, app_loaded = make_app_require(path, env)
    env.require = app_require
    env.package = {loaded = app_loaded}
    self.app = app
    local ok, err = pcall(function()
        local chunk = paths.check(loadfile(path .. "/app.lua", "t", env))
        chunk(table.unpack(args))
        for _, name in ipairs({"init", "update", "deinit"}) do
            local hook = rawget(env, name)
            assert(hook == nil or type(hook) == "function", name .. " must be a function")
        end
        if app.exit_requested then return end
        local start = rawget(env, "init")
        if start then start() end
    end)
    if not ok then
        self.report(err)
        self:finish("error")
        return nil, err
    end
    if app.exit_requested or not rawget(env, "update") then self:finish("exit") end
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
    local ok, err = pcall(rawget(app.env, "update"), dt)
    if not ok then
        self.report(err)
        self:finish("error")
    elseif app.exit_requested then
        self:finish("exit")
    end
end

return Runner
