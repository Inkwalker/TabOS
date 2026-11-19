local paths = require("paths")
local make_bundle_require = require("bundle_require")

return function(config, request, context)
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
    local picker = provider.new(request, context)
    assert(type(picker) == "table" and type(picker.update) == "function"
        and type(picker.draw) == "function" and type(picker.close) == "function",
        entry .. " must create a picker with update, draw, and close")
    return picker
end
