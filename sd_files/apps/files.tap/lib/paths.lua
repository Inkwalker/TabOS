local Paths = {}

function Paths.join(parent, name)
    return (parent == "/" and "" or parent) .. "/" .. name
end

function Paths.parent(path)
    local parent = path:match("^(.*)/[^/]+$")
    return parent and parent ~= "" and parent or "/"
end

function Paths.name(path)
    return path:match("[^/]+$") or "/"
end

function Paths.volume(path)
    return path:match("^/[^/]+")
end

function Paths.key(path)
    return Paths.volume(path) == "/sd" and fs.fat_name_key(path) or path
end

function Paths.protected(path)
    return Paths.parent(path) == "/"
end

function Paths.list(path)
    if path == "/" then return {{name = "sd", type = "dir"}, {name = "rec", type = "dir"}} end
    return fs.list(path)
end

function Paths.entries(folder, descending)
    local children, err = Paths.list(folder)
    if not children then return nil, err or "Directory unavailable" end
    local entries = {}
    for _, child in ipairs(children) do
        local path = Paths.join(folder, child.name)
        local info = child.type and child or fs.stat(path)
        local kind = info and info.type
        local app_entry = kind == "dir" and child.name:sub(-4):lower() == ".tap"
            and fs.stat(Paths.join(path, "app.lua"))
        entries[#entries + 1] = {
            path = path, name = child.name, key = Paths.key(path),
            type = kind, order = child.name:lower(),
            app_bundle = app_entry and app_entry.type == "file",
        }
    end
    table.sort(entries, function(a, b)
        if (a.type == "dir") ~= (b.type == "dir") then return a.type == "dir" end
        if a.order == b.order then return a.name < b.name end
        if descending then return a.order > b.order end
        return a.order < b.order
    end)
    return entries
end

-- Resolve to names actually listed by the filesystem. In particular, do not
-- let alternate FAT short names bypass the checks for pasting into descendants.
function Paths.directory(path, base)
    if path:find("[%z\\]") then return nil, "Invalid path" end
    if path:sub(1, 1) ~= "/" then path = Paths.join(base, path) end
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            parts[#parts] = nil
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    local directory = "/"
    for _, part in ipairs(parts) do
        local entries, err = Paths.list(directory)
        if not entries then return nil, err end
        local requested = Paths.key(Paths.join(directory, part))
        local found
        for _, entry in ipairs(entries) do
            local child = Paths.join(directory, entry.name)
            if Paths.key(child) == requested then
                local info = entry.type and entry or fs.stat(child)
                if info and info.type == "dir" then found = child end
                break
            end
        end
        if not found then return nil, "Folder not found: " .. requested end
        directory = found
    end
    return directory
end

function Paths.valid_name(name)
    return name ~= "" and name ~= "." and name ~= ".."
        and not name:find('[%c/\\:*?"<>|]') and not name:find("[ .]$")
end

return Paths
