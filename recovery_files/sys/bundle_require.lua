local paths = require("paths")

return function(root, env)
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
