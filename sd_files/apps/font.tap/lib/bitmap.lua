local Bitmap = {}

function Bitmap.pixel(glyph, x, y)
    return (glyph.rows[y + 1] & (1 << (glyph.width - x - 1))) ~= 0
end

function Bitmap.paint(glyph, x, y, ink)
    local mask = 1 << (glyph.width - x - 1)
    local row = glyph.rows[y + 1]
    local next_row = ink and (row | mask) or (row & ~mask)
    glyph.rows[y + 1] = next_row
    return row ~= next_row
end

function Bitmap.resize(glyph, width, height)
    local old_height = #glyph.rows
    if old_height == height and glyph.width == width then return false end

    local shift = width - (glyph.width or 0)
    local rows = {}
    for y = 1, height do
        local row = glyph.rows[y] or 0
        if shift < 0 then
            row = row >> -shift
        else
            row = row << shift
        end
        rows[y] = row
    end
    -- An omitted offset keeps the bitmap on the baseline when its height changes.
    if glyph.y_offset == nil and height > 128 then glyph.y_offset = -128 end
    glyph.width, glyph.rows = width, rows
    return true
end

return Bitmap
