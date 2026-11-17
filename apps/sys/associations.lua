local paths = require("paths")
local Registry = {}
Registry.__index = Registry

local settings_path = "/sd/sys/apps.ltab"

local function normalize(path)
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("[%c\\]") then
        return nil
    end
    return paths.resolve_path(path, "/")
end

local function key(path)
    return path:match("^/sd/") and fs.fat_name_key(path) or path
end

local function valid_extension(extension)
    return type(extension) == "string" and extension:match('^%.[^%./\\:*?"<>|%c%s]+$') ~= nil
end

local function extensions(declared)
    local result = {}
    if declared == nil then return result end
    if type(declared) ~= "table" then return nil end
    local length = #declared
    for index, extension in pairs(declared) do
        if math.type(index) ~= "integer" or index < 1 or index > length
            or not valid_extension(extension) then return nil end
        result[extension:lower()] = true
    end
    for index = 1, length do
        if declared[index] == nil then return nil end
    end
    return result
end

function Registry.bundle(path, association)
    path = normalize(path)
    if not path or path:sub(-4):lower() ~= ".tap" then return nil end
    local entry = fs.stat(path .. "/app.lua")
    if not entry or entry.type ~= "file" then return nil end
    local manifest = fs.read_table(path .. "/manifest.ltab")
    if association and not manifest then return nil end
    manifest = manifest or {}
    local supported = extensions(manifest.file_extensions)
    if association and not supported then return nil end
    local name = manifest.name
    if type(name) ~= "string" or not name:find("%S") or name:find("%c") then
        local filename = path:match("[^/]+$")
        name = #filename > 4 and filename:sub(1, -5) or filename
    end
    local icon = manifest.icon
    if type(icon) ~= "string" or icon == "" or icon:find("[%c\\:]") or icon:sub(1, 1) == "/" then
        icon = nil
    elseif ("/" .. icon .. "/"):find("/../", 1, true) then
        icon = nil
    end
    return {path = path, name = name, window = manifest.window == true,
        icon_path = icon and path .. "/" .. icon, extensions = supported}
end

function Registry.new(files_path)
    return setmetatable({files_path = files_path, apps = {}, preferences = {}}, Registry)
end

function Registry:refresh()
    local stored, err, code = fs.read_table(settings_path)
    if stored or code == 2 then
        local preferences = {}
        for extension, path in pairs(stored or {}) do
            if valid_extension(extension) and type(path) == "string" then
                preferences[extension:lower()] = path
            end
        end
        self.preferences = preferences
    end
    local apps = {}
    local function register(path)
        local id = key(path)
        if apps[id] then return end
        apps[id] = Registry.bundle(path, true)
    end
    local entries, list_error, list_code = fs.list("/sd/apps")
    for _, entry in ipairs(entries or {}) do
        if entry.type ~= "file" and entry.name:sub(-4):lower() == ".tap" then
            register("/sd/apps/" .. entry.name)
        end
    end
    for _, path in pairs(self.preferences) do
        local normalized = normalize(path)
        if normalized then register(normalized) end
    end
    self.apps = apps
    if not stored and code ~= 2 then return nil, err end
    if not entries and list_code ~= 2 then return nil, list_error end
    return true
end

function Registry:resolve(request)
    local path = normalize(request.path)
    if not path then return nil, "Expected an absolute file path" end
    local mode = request.mode
    if mode ~= nil and mode ~= "browse" and mode ~= "with" then
        return nil, "Unknown file opening mode"
    end
    local info, err
    if path == "/" then info = {type = "dir"} else info, err = fs.stat(path) end
    if not info then return nil, err or ("Cannot open " .. path) end
    if info.type == "dir" then
        if mode == "with" then return nil, "Open With requires a file" end
        local app = not mode and Registry.bundle(path)
        if app then return {app = app} end
        app = Registry.bundle(self.files_path)
        if not app or not app.window then return nil, "Configured Files application is unavailable" end
        return {app = app, args = {path}}
    end
    if mode == "browse" then return nil, "Browse Contents requires a folder" end
    local extension = path:match("[^/]+$"):match("(%.[^%.]+)$")
    extension = extension and extension:lower()
    local preferred = mode ~= "with" and self.preferences[extension]
    if preferred then
        local normalized = normalize(preferred)
        local app = normalized and self.apps[key(normalized)] and Registry.bundle(normalized, true)
        if app and app.extensions[extension] then return {app = app, args = {path}} end
        return nil, "Saved handler for " .. extension .. " is unavailable: " .. preferred
    end
    local candidates = {}
    for _, app in pairs(self.apps) do
        if app.extensions[extension] then candidates[#candidates + 1] = app end
    end
    if #candidates == 0 then return nil, "No registered application supports " .. path end
    if #candidates == 1 and mode ~= "with" then
        return self:choose(path, extension, candidates[1], false)
    end
    table.sort(candidates, function(a, b)
        local left, right = a.name:lower(), b.name:lower()
        if left == right then return a.path < b.path end
        return left < right
    end)
    return {candidates = candidates, path = path, extension = extension}
end

function Registry:choose(path, extension, candidate, always)
    local app = self.apps[key(candidate.path)] and Registry.bundle(candidate.path, true)
    if not app or not app.extensions[extension] then
        return nil, "Handler for " .. extension .. " is unavailable: " .. candidate.path
    end
    if always then
        local updated = {}
        for ext, previous in pairs(self.preferences) do updated[ext] = previous end
        updated[extension] = app.path
        local ok, detail = fs.write_table(settings_path, updated)
        if not ok then return nil, detail or "Cannot save file association" end
        self.preferences = updated
        return {app = app, args = {path}, warning = detail}
    end
    return {app = app, args = {path}}
end

return Registry
