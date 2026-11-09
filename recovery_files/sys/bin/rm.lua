local paths = require("paths")

return {
    description = "Remove a file.",
    operands = "file",
    count = 1,
    handler = function(_, path)
        paths.check(paths.path_type(path) == "file", path .. ": not a file")
        paths.check(fs.remove(path))
    end,
}
