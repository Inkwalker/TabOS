local Draft = require("draft")
local History = require("history")

local Checkpoint = {}
local id_pattern = "^s%x%x%x%x%x%x%x$"

local function remove(directory)
    fs.remove(directory .. "/draft.rgb")
    fs.remove(directory .. "/draft.png")
    fs.remove(directory .. "/history.bin")
    fs.remove(directory)
end

local function reserve(root)
    local info, err, code = fs.stat(root)
    if not info then
        if code ~= 2 then return nil, err end
        local ok
        ok, err = fs.mkdir(root)
        if not ok then return nil, err end
    elseif info.type ~= "dir" then
        return nil, "Sprite checkpoint path is not a directory"
    end

    for _ = 1, 32 do
        local id = string.format("s%07x", math.random(0, 0xfffffff))
        local ok
        ok, err, code = fs.mkdir(root .. "/" .. id)
        if ok then return id end
        if code ~= 17 then return nil, err end
    end
    return nil, "No free sprite checkpoint name"
end

local function write_file(path, write)
    local file, err = fs.open_new(path)
    if not file then return nil, err end
    local ok, write_error = write(file)
    local closed, close_error = file:close()
    if ok and closed then return true end
    return nil, write_error or close_error
end

function Checkpoint.write(root, image, history)
    local id, err = reserve(root)
    if not id then return nil, err end
    local directory = root .. "/" .. id
    local ok
    ok, err = write_file(directory .. "/draft.rgb", function(file)
        return Draft.write(file, image)
    end)
    if ok then
        ok, err = write_file(directory .. "/history.bin", function(file)
            return history:write(file, image.width, image.height)
        end)
        if ok then return id end
    end
    remove(directory)
    return nil, err or "Sprite checkpoint write failed"
end

local function read_draft(directory)
    local file, err, code = io.open(directory .. "/draft.rgb", "rb")
    if not file then
        if code == 2 then return gfx.load_sprite(directory .. "/draft.png") end
        return nil, err
    end
    local image
    image, err = Draft.read(file)
    local closed, close_error = file:close()
    if image and closed then return image end
    if image then image:close() end
    return nil, err or close_error
end

function Checkpoint.read(root, id, handlers)
    if type(id) ~= "string" or not id:match(id_pattern) then
        return nil, "Invalid sprite checkpoint name"
    end
    local directory = root .. "/" .. id
    local image, err = read_draft(directory)
    if not image then return nil, err end
    local file
    file, err = io.open(directory .. "/history.bin", "rb")
    if file then
        local history
        history, err = History.read(file, handlers, image.width, image.height)
        local closed, close_error = file:close()
        if history and closed then return image, history end
        err = err or close_error
    end
    image:close()
    return nil, err
end

function Checkpoint.clear(root)
    -- After a successful launch, the runner consumes the bundle's only session.
    for _, entry in ipairs(fs.list(root) or {}) do
        if entry.type == "dir" and entry.name:match(id_pattern) then
            remove(root .. "/" .. entry.name)
        end
    end
end

return Checkpoint
