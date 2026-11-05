local paths = require("paths")

return {
    description = "Rename or move a file or directory within its volume.",
    operands = "source destination",
    count = 2,
    handler = function(cwd, source, destination)
        local kind = paths.path_type(source)
        if kind == "directory" then
            paths.check_movable_directory(source, cwd)
        end
        destination = paths.destination_path(source, destination)
        if kind == "directory" then
            paths.check(not paths.is_within(destination, source), source .. ": cannot move into itself")
        end
        paths.check(fs.rename(source, destination))
    end,
}
