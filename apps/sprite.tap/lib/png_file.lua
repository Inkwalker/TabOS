local PngFile = {}

local function sibling(directory, extension)
    for _ = 1, 32 do
        local path = string.format("%s/s%07x.%s", directory, math.random(0, 0xfffffff), extension)
        local info, err, code = fs.stat(path)
        if not info then
            if code == 2 then return path end
            return nil, err
        end
    end
    return nil, "No free temporary filename"
end

local function discard_temp(path, message)
    if not fs.remove(path) then
        return nil, "Save failed. Temp kept as " .. path:match("[^/]+$")
    end
    return nil, message
end

local function same_file(current, previous)
    return current.type == "file" and current.size == previous.size and current.mtime == previous.mtime
end

function PngFile.save(sprite, path, source, create)
    local original, err, code = fs.stat(path)
    if create then
        if original then return nil, "Save target already exists" end
        if code ~= 2 then return nil, err end
    else
        if not original then return nil, err end
        if original.type ~= "file" then return nil, "Save target is not a file" end
        if source and not same_file(original, source) then return nil, "Save target changed since opening" end
    end

    local directory = path:match("^(.*)/[^/]+$")
    local temp, backup, handle
    temp, err = sibling(directory, "tmp")
    if not temp then return nil, err end
    if original then
        backup, err = sibling(directory, "bak")
        if not backup then return nil, err end
    end

    handle, err = fs.open_new(temp)
    if not handle then return nil, err end
    local ok
    ok, err = handle:close()
    if not ok then return discard_temp(temp, err) end
    ok, err = sprite:save(temp)
    if not ok then return discard_temp(temp, err) end

    -- FAT renames require an unused destination, including when creating a new file.
    if create then
        ok, err = fs.rename(temp, path)
        if not ok then return discard_temp(temp, err) end
        return true
    end

    local current
    current, err = fs.stat(path)
    if not current then return discard_temp(temp, err) end
    if not same_file(current, original) then
        return discard_temp(temp, "Save target changed during save")
    end

    -- Keep the original until replacement succeeds.
    ok, err = fs.rename(path, backup)
    if not ok then return discard_temp(temp, err) end
    ok, err = fs.rename(temp, path)
    if not ok then
        if not fs.rename(backup, path) then
            return nil, "Save failed. Original in " .. backup:match("[^/]+$")
        end
        return discard_temp(temp, err)
    end

    if not fs.remove(backup) then
        return true, "Saved. Backup kept as " .. backup:match("[^/]+$")
    end
    return true
end

return PngFile
