local paths = require("paths")

return {
    description = "List the current directory or a path.",
    operands = "[path]",
    count = 1,
    handler = function(cwd, path)
        path = path or cwd
        local names = {}
        if path == "/" then
            -- ESP-IDF mounts these volumes separately and has no directory at /.
            for _, name in ipairs({"rec", "sd"}) do
                if fs.stat("/" .. name) then
                    names[#names + 1] = name
                end
            end
        elseif paths.path_type(path) == "dir" then
            for _, entry in ipairs(paths.check(fs.list(path))) do
                names[#names + 1] = entry.name
            end
        else
            names[1] = path:match("[^/]+$")
        end
        table.sort(names)
        for _, name in ipairs(names) do
            shell.write(name)
        end
    end,
}
