local Draft = {}

local header_format = "<c4I2I2"
local header_size = string.packsize(header_format)
local pixel_format = "<I2"
local pixel_size = string.packsize(pixel_format)
local chunk_pixels = 256
local chunk_format = "<" .. ("I2"):rep(chunk_pixels)

function Draft.write(file, image)
    local width, height = image.width, image.height
    local ok, err = file:write(string.pack(header_format, "SPD1", width, height))
    if not ok then return nil, err end

    local total = width * height
    local colors = {}
    for first = 0, total - 1, chunk_pixels do
        local count = math.min(chunk_pixels, total - first)
        for offset = 1, count do
            local index = first + offset - 1
            colors[offset] = image:pget(index % width, index // width)
        end
        local format = count == chunk_pixels and chunk_format or "<" .. ("I2"):rep(count)
        ok, err = file:write(string.pack(format, table.unpack(colors, 1, count)))
        if not ok then return nil, err end
    end
    return true
end

function Draft.read(file)
    local invalid = "Invalid sprite draft"
    local header, err = file:read(header_size)
    if not header or #header ~= header_size then return nil, err or invalid end
    local magic, width, height = string.unpack(header_format, header)
    local total = width * height
    if magic ~= "SPD1" or width < 1 or width > 32767 or height < 1 or height > 32767
        or total > 65536 then
        return nil, invalid
    end

    local size = total * pixel_size
    local pixels
    pixels, err = file:read(size)
    if not pixels or #pixels ~= size then return nil, err or invalid end
    local trailing
    trailing, err = file:read(1)
    if trailing or err then return nil, err or invalid end

    local image
    image, err = gfx.create_sprite(width, height)
    if not image then return nil, err end
    local window_width, window_height = gfx.width, gfx.height
    gfx.target(width, height)
    local position = 1
    for index = 0, total - 1 do
        local color
        color, position = string.unpack(pixel_format, pixels, position)
        if color ~= 0 then gfx.pset(index % width, index // width, color) end
    end
    gfx.flip(image)
    gfx.target(window_width, window_height)
    return image
end

return Draft
