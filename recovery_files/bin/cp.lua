local paths = require("paths")

return {
    description = "Copy a file to a new path or into a directory.",
    operands = "source destination",
    count = 2,
    handler = function(_, source, destination)
        paths.check(paths.path_type(source) == "file", source .. ": not a file")
        destination = paths.destination_path(source, destination)
        local input_file = paths.check(io.open(source, "rb"))
        local output_file, open_error = io.open(destination, "wb")
        if not output_file then
            input_file:close()
            error(open_error, 0)
        end

        local copy_error
        while true do
            local data, read_error = input_file:read(4096)
            if not data then
                copy_error = read_error
                break
            end
            local written, write_error = output_file:write(data)
            if not written then
                copy_error = write_error
                break
            end
        end
        local _, input_error = input_file:close()
        local _, output_error = output_file:close()
        copy_error = copy_error or input_error or output_error
        if copy_error then
            local _, cleanup_error = fs.remove(destination)
            if cleanup_error then
                shell.write("Could not remove partial copy: " .. cleanup_error)
            end
            error(copy_error, 0)
        end
    end,
}
