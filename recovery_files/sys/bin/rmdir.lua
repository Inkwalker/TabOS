local paths = require("paths")

return {
    description = "Remove an empty directory.",
    operands = "directory",
    count = 1,
    handler = function(cwd, path)
        paths.check(paths.path_type(path) == "directory", path .. ": not a directory")
        paths.check_movable_directory(path, cwd)
        paths.check(fs.remove(path))
    end,
}
