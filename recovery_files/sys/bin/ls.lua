local paths = require("paths")

return {
    description = "List the current directory or a path.",
    operands = "[path]",
    count = 1,
    handler = function(cwd, path)
        path = path or cwd
        local entries = {}
        if path == "/" then
            -- ESP-IDF mounts these volumes separately and has no directory at /.
            for _, name in ipairs({"rec", "sd"}) do
                if fs.stat("/" .. name) then
                    entries[#entries + 1] = name
                end
            end
        elseif paths.path_type(path) == "directory" then
            entries = paths.check(fs.list(path))
        else
            entries[1] = path:match("[^/]+$")
        end
        table.sort(entries)
        for _, name in ipairs(entries) do
            shell.write(name)
        end
    end,
}
