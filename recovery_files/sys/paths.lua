local paths = {}

function paths.resolve_path(path, cwd)
    if path:sub(1, 1) ~= "/" then
        path = cwd .. "/" .. path
    end
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            parts[#parts] = nil
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return "/" .. table.concat(parts, "/")
end

function paths.check(result, err)
    if not result then
        error(err, 0)
    end
    return result
end

function paths.path_type(path)
    if path == "/" then
        return "directory"
    end
    return paths.check(fs.stat(path)).type
end

function paths.destination_path(source, destination)
    local info = fs.stat(destination)
    if destination == "/" or (info and info.type == "directory") then
        destination = (destination == "/" and "" or destination) .. "/" .. source:match("[^/]+$")
        info = fs.stat(destination)
    end
    paths.check(not info, destination .. ": already exists")
    return destination
end

function paths.is_within(path, directory)
    path, directory = path:lower(), directory:lower()
    return path == directory or path:sub(1, #directory + 1) == directory .. "/"
end

function paths.check_movable_directory(path, cwd)
    paths.check(path:find("/", 2), path .. ": cannot modify a mount point")
    paths.check(not paths.is_within(cwd, path), path .. ": directory is in use")
end

return paths
