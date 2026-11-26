local paths = require("paths")
local make_bundle_require = require("bundle_require")
local Gate = require("input_gate")
local FileDialog = {}
FileDialog.__index = FileDialog

local function load_picker(config, options, context)
    local entry = type(config.dialogs) == "table" and config.dialogs.file or nil
    if entry == nil and type(config.files_app) == "string" then
        entry = config.files_app .. "/picker.lua"
    end
    assert(type(entry) == "string" and entry:sub(1, 1) == "/" and not entry:find("[%c\\]"),
        "Configure an absolute file picker path")
    entry = paths.resolve_path(entry, "/")
    local root = entry:match("^(.*)/[^/]+$")
    assert(root, "Expected a file picker script")
    local env = setmetatable({
        input = context.input,
        os = {path = function(path) return paths.resolve_path(path, root) end},
    }, {__index = _ENV})
    env._G = env
    local bundled_require, loaded = make_bundle_require(root, env)
    env.require, env.package = bundled_require, {loaded = loaded}
    local provider = assert(loadfile(entry, "t", env))()
    assert(type(provider) == "table" and type(provider.new) == "function",
        entry .. " must return a table with new(request, context)")
    local picker = provider.new(options, context)
    assert(type(picker) == "table" and type(picker.update) == "function"
        and type(picker.draw) == "function" and type(picker.close) == "function",
        entry .. " must create a picker with update, draw, and close")
    return picker
end

function FileDialog.new(config, request, context)
    return setmetatable({config = config, options = request.options, context = context,
        callback = request.callback}, FileDialog)
end

local function start(self)
    local context = self.context
    self.input = Gate.new(context.input)
    local ok, picker = pcall(function()
        if context.capture then
            local frame = assert(gfx.create_sprite(gfx.width, gfx.height))
            local captured, err = pcall(gfx.flip, frame)
            if not captured then
                frame:close()
                error(err, 0)
            end
            self.frame = frame
        end
        return load_picker(self.config, self.options, {
            input = self.input, colors = context.colors, width = gfx.width, height = gfx.height,
        })
    end)
    if not ok then return true, nil, tostring(picker) end
    self.picker = picker
end

function FileDialog:update(dt)
    if not self.picker then return start(self) end
    self.input.refresh()
    if self.input.keyp(1, 1) then return true end
    if self.error then return true, nil, self.error end

    local ok, done, path, err = pcall(self.picker.update, self.picker, dt)
    if not ok then return true, nil, tostring(done) end
    if not done then return end
    if path ~= nil and (type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("[%c\\]")) then
        return true, nil, "The file picker returned an invalid path"
    end
    if err ~= nil then return true, nil, tostring(err) end
    return true, path
end

function FileDialog:draw_background()
    if not self.picker then return false end
    if self.frame then
        gfx.target()
        gfx.spr(self.frame, 0, 0)
    end
    return true
end

function FileDialog:draw()
    local ok, err = pcall(self.picker.draw, self.picker)
    if not ok then self.error = tostring(err) end
end

function FileDialog:close(path, err)
    if self.picker then
        local ok, detail = pcall(self.picker.close, self.picker)
        if not ok then path, err = nil, err or tostring(detail) end
    end
    local frame = self.frame
    if frame then
        gfx.target(frame.width, frame.height)
        gfx.spr(frame, 0, 0)
        frame:close()
    end
    self.picker, self.frame = nil, nil
    return path, err
end

return FileDialog
