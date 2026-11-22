local vertices = {
    {-1, -1, -1}, {1, -1, -1}, {1, 1, -1}, {-1, 1, -1},
    {-1, -1, 1}, {1, -1, 1}, {1, 1, 1}, {-1, 1, 1},
}

-- Outward winding, starting at the top-left texture corner on each face.
-- The face order matches the 3 by 2 atlas, read left to right.
local faces = {
    {8, 5, 6, 7, gfx.rgb(34, 160, 177)},
    {7, 6, 2, 3, gfx.rgb(219, 116, 57)},
    {4, 8, 7, 3, gfx.rgb(224, 183, 84)},
    {3, 2, 1, 4, gfx.rgb(102, 111, 206)},
    {4, 1, 5, 8, gfx.rgb(186, 79, 135)},
    {5, 1, 2, 6, gfx.rgb(77, 159, 109)},
}

local tile_size = 32
local background = gfx.rgb(14, 20, 29)
local panel = gfx.rgb(24, 34, 47)
local divider = gfx.rgb(52, 68, 84)
local ink = gfx.rgb(226, 238, 248)
local muted = gfx.rgb(150, 172, 191)
local accent = gfx.rgb(106, 222, 223)

local projected = {}
for i = 1, #vertices do projected[i] = {} end

local texture
local textured = true
local yaw, pitch = 0.55, 0.45
local camera_distance = 4.5
local stats_elapsed = 0
local fps_label, cpu0_label, cpu1_label = "FPS: --", "CPU0: --%", "CPU1: --%"

local function project(center_x, center_y, focal_length)
    local cy, sy = math.cos(yaw), math.sin(yaw)
    local cp, sp = math.cos(pitch), math.sin(pitch)
    for i, vertex in ipairs(vertices) do
        local x, y, z = vertex[1], vertex[2], vertex[3]
        local turned_x, turned_z = x * cy + z * sy, z * cy - x * sy
        local rotated_y, rotated_z = y * cp - turned_z * sp, y * sp + turned_z * cp
        local scale = focal_length / (camera_distance - rotated_z)
        local point = projected[i]
        point.x = center_x + scale * turned_x
        point.y = center_y - scale * rotated_y
        point.px = math.floor(point.x + 0.5)
        point.py = math.floor(point.y + 0.5)
    end
end

local function draw_cube()
    for i, face in ipairs(faces) do
        local a, b, c, d = projected[face[1]], projected[face[2]], projected[face[3]], projected[face[4]]
        local area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        if area < 0 then -- Screen Y points down, which flips the projected winding.
            if textured then
                local u, v = (i - 1) % 3 * tile_size, (i - 1) // 3 * tile_size
                local u0, v0 = u + 0.25, v + 0.25
                local u1, v1 = u + tile_size - 0.25, v + tile_size - 0.25
                gfx.ttri(texture, a.px, a.py, b.px, b.py, c.px, c.py, u0, v0, u0, v1, u1, v1)
                gfx.ttri(texture, a.px, a.py, c.px, c.py, d.px, d.py, u0, v0, u1, v1, u1, v0)
            else
                local color = face[5]
                gfx.tri(a.px, a.py, b.px, b.py, c.px, c.py, color)
                gfx.tri(a.px, a.py, c.px, c.py, d.px, d.py, color)
            end
        end
    end
end

local function draw()
    local panel_width = 112
    local split, height = gfx.width - panel_width, gfx.height
    gfx.cls(background)
    local focal_length = math.min(split, height) * 0.22 * camera_distance
    project(split / 2, height / 2, focal_length)
    draw_cube()

    gfx.rectfill(split, 0, panel_width, height, panel)
    gfx.line(split, 0, split, height - 1, divider)
    local x = split + 10
    gfx.print(x, 17, "ROTATING CUBE", ink)
    gfx.print(x, 38, textured and "Textured" or "Flat colors", accent)
    gfx.print(x, 71, fps_label, ink)
    gfx.print(x, 86, cpu0_label, ink)
    gfx.print(x, 101, cpu1_label, ink)
    gfx.print(x, height - 35, "TAB  Switch mode", muted)
    gfx.print(x, height - 21, "ESC  Exit", muted)
end

function init()
    texture = assert(gfx.load_sprite(os.path("texture.png")))
    sys.cpu_load() -- Prime the utilization counters before the first timed sample.
    draw()
end

function update(dt)
    if input.keyp(1, 1) then os.exit(); return end
    if input.keyp(3, 1) then textured = not textured end -- Tab

    stats_elapsed = stats_elapsed + dt
    if stats_elapsed >= 0.5 then
        local fps = gfx.presenter_fps()
        local core0, core1 = sys.cpu_load()
        if fps > 0 then fps_label = string.format("FPS: %.0f", fps) end
        if core0 ~= nil then cpu0_label = string.format("CPU0: %.0f%%", core0) end
        if core1 ~= nil then cpu1_label = string.format("CPU1: %.0f%%", core1) end
        stats_elapsed = 0
    end

    local step = math.min(dt, 0.1)
    yaw = (yaw + 0.9 * step) % (2 * math.pi)
    pitch = (pitch + 0.6 * step) % (2 * math.pi)
    draw()
end

function deinit()
    if texture then texture:close() end
end
