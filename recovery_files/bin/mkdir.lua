local paths = require("paths")

return {
    description = "Create a directory.",
    operands = "directory",
    count = 1,
    handler = function(_, path)
        paths.check(fs.mkdir(path))
    end,
}
