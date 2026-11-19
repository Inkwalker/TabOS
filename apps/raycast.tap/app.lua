-- A compact Wolfenstein-style gfx.tline demo. One map cell is one unit.
-- Render a centered square viewport with 180 wall rays.
local W, H = 180, 180
local VIEW_X = math.floor((gfx.width - W) / 2)
local VIEW_Y = math.floor((gfx.height - H) / 2)
local HALF_H = H / 2
local TEX = 32
local PLANE = 0.66 -- Approximately 67 degrees horizontal field of view.
local FOCAL = W / (2 * PLANE)
local MAX_DISTANCE = 6 -- Camera depth in map cells; also limits DDA traversal.
local floor, ceil, abs = math.floor, math.ceil, math.abs
local min, max, cos, sin, sqrt = math.min, math.max, math.cos, math.sin, math.sqrt
local tline, rectfill = gfx.tline, gfx.rectfill
local print_text, cls, load_sprite = gfx.print, gfx.cls, gfx.load_sprite
local key, keyp = input.key, input.keyp
local cpu_load = sys.cpu_load
local map = {
    "1111111111111111",
    "1000000000000001",
    "1022200010222001",
    "1000000010000001",
    "1000000010000001",
    "1110111110111001",
    "1000000000001001",
    "1000200020001001",
    "1000000000000001",
    "1000200020001001",
    "1000000000001001",
    "1111101110111101",
    "1000001000000001",
    "1000000000222001",
    "1000000000000001",
    "1111111111111111",
}
-- Keep the map easy to edit, but decode it once instead of parsing strings
-- at every ray step and collision query.
for y, row in ipairs(map) do
    local cells = {}
    for x = 1, #row do
        cells[x] = assert(tonumber(row:sub(x, x)), "invalid map cell")
    end
    map[y] = cells
end

-- Projection depends only on the fixed viewport and field of view.
local row_depth, column_camera_x = {}, {}
-- Reused each frame: wall-to-floor edges and horizontal texture span data.
local floor_top, span_start = {}, {}
local floor_u, floor_v, floor_du, floor_dv = {}, {}, {}, {}
local FIRST_FLOOR_ROW = math.max(HALF_H,
    ceil(HALF_H + FOCAL * 0.5 / MAX_DISTANCE - 0.5))
local CLIP_TOP = max(0, ceil(HALF_H - FOCAL * 0.5 / MAX_DISTANCE - 0.5))
local CLIP_BOTTOM = min(H - 1, FIRST_FLOOR_ROW - 1)
for y = FIRST_FLOOR_ROW, H - 1 do
    row_depth[y] = FOCAL * 0.5 / abs(y + 0.5 - HALF_H)
end
for x = 0, W - 1 do
    column_camera_x[x] = 2 * (x + 0.5) / W - 1
end

local px, py, angle = 3.5, 3.5, 0
local walls, ground = {}, nil
local sprites = {}
local frames, elapsed, fps_label = 0, 0, "FPS --"
local cpu0_label, cpu1_label = "CPU0 --", "CPU1 --"
local ink = gfx.rgb(218, 208, 175)
local hud = gfx.rgb(23, 26, 29)
local ceiling_color = gfx.rgb(45, 49, 55)
local distant_floor_color = gfx.rgb(40, 39, 34)

local function cell(x, y)
    local row = map[floor(y) + 1]
    return row and row[floor(x) + 1] or 1
end

local function load(name)
    local sprite = assert(load_sprite(os.path("spr/" .. name .. ".png")))
    sprites[#sprites + 1] = sprite -- Keep partial initialization safe to clean up.
    assert(sprite.width == TEX and sprite.height == TEX, "textures must be 32x32")
    return sprite
end

local function free(x, y)
    local r = 0.18
    return cell(x - r, y - r) == 0 and cell(x + r, y - r) == 0
        and cell(x - r, y + r) == 0 and cell(x + r, y + r) == 0
end

local function move(dx, dy)
    -- Separate axes allow sliding along walls and around corners.
    if free(px + dx, py) then px = px + dx end
    if free(px, py + dy) then py = py + dy end
end

local function print_stat(text, y)
    local x = VIEW_X + W - #text * 6 - 3
    print_text(x, y, text, ink)
end

local function render()
    local dir_x, dir_y = cos(angle), sin(angle)
    local plane_x, plane_y = -dir_y * PLANE, dir_x * PLANE

    -- Clear every frame so walls leaving the view cannot leave stale pixels.
    rectfill(VIEW_X, VIEW_Y, W, HALF_H, ceiling_color)
    rectfill(VIEW_X, VIEW_Y + HALF_H, W, H - HALF_H, distant_floor_color)
    -- A black far-plane wall closes the view where rays reach the distance cap.
    if CLIP_BOTTOM >= CLIP_TOP then
        rectfill(VIEW_X, VIEW_Y + CLIP_TOP, W, CLIP_BOTTOM - CLIP_TOP + 1, 0x0000)
    end

    -- At a fixed screen row, floor depth is constant. A horizontal
    -- tline can therefore step linearly through world-space texture positions.
    -- Rows beyond MAX_DISTANCE retain the solid distant-floor color.
    for y = FIRST_FLOOR_ROW, H - 1 do
        local depth = row_depth[y]
        local step_x = depth * 2 * plane_x / W
        local step_y = depth * 2 * plane_y / W
        local world_x = px + depth * (dir_x - plane_x) + step_x * 0.5
        local world_y = py + depth * (dir_y - plane_y) + step_y * 0.5
        floor_u[y], floor_v[y] = world_x * TEX, world_y * TEX
        floor_du[y], floor_dv[y] = step_x * TEX, step_y * TEX
    end

    for x = 0, W - 1 do
        floor_top[x] = FIRST_FLOOR_ROW -- No wall hit: floor is fully visible.
        local camera_x = column_camera_x[x]
        local ray_x = dir_x + plane_x * camera_x
        local ray_y = dir_y + plane_y * camera_x
        local mx, my = floor(px), floor(py)
        local delta_x = ray_x == 0 and math.huge or abs(1 / ray_x)
        local delta_y = ray_y == 0 and math.huge or abs(1 / ray_y)
        local sx, sy = ray_x < 0 and -1 or 1, ray_y < 0 and -1 or 1
        local side_x = (ray_x < 0 and px - mx or mx + 1 - px) * delta_x
        local side_y = (ray_y < 0 and py - my or my + 1 - py) * delta_y
        local side, material, distance = nil, 0, 0
        -- DDA visits grid boundaries instead of taking small ray steps.
        repeat
            if side_x < side_y then
                distance = side_x
                side_x, mx, side = side_x + delta_x, mx + sx, 1
            else
                distance = side_y
                side_y, my, side = side_y + delta_y, my + sy, 2
            end
            if distance > MAX_DISTANCE then break end
            -- DDA coordinates are already integers; skip world-cell flooring.
            local row = map[my + 1]
            material = row and row[mx + 1] or 1
        until material ~= 0

        if material ~= 0 then
            -- Rays use an unnormalized camera plane: distance is perpendicular
            -- camera depth already, so walls stay straight without fish-eye.
            distance = max(distance, 0.001)
            local wall_u = side == 1 and py + distance * ray_y or px + distance * ray_x
            wall_u = floor((wall_u - floor(wall_u)) * TEX)
            if (side == 1 and ray_x > 0) or (side == 2 and ray_y < 0) then
                wall_u = TEX - 1 - wall_u
            end
            local projected = FOCAL / distance
            local top = max(0, ceil(HALF_H - projected * 0.5 - 0.5))
            local bottom = min(H - 1, ceil(HALF_H + projected * 0.5 - 0.5) - 1)
            floor_top[x] = max(FIRST_FLOOR_ROW, bottom + 1)
            if bottom >= top then
                -- Start UV at the visible pixel, preserving scale near walls.
                local v = ((top + 0.5 - HALF_H) / projected + 0.5) * TEX
                tline(walls[material][side], VIEW_X + x, VIEW_Y + top,
                    VIEW_X + x, VIEW_Y + bottom,
                    wall_u, v, 0, TEX / projected)
            end
        end
    end

    -- Sweep wall bottoms to open/close visible horizontal floor spans. Only
    -- process rows whose visibility changes, rather than testing every pixel.
    local previous = H
    for x = 0, W do
        local current = x < W and min(H, floor_top[x]) or H
        if current < previous then
            for y = current, previous - 1 do span_start[y] = x end
        elseif current > previous then
            for y = previous, current - 1 do
                local first = span_start[y]
                tline(ground, VIEW_X + first, VIEW_Y + y,
                    VIEW_X + x - 1, VIEW_Y + y,
                    floor_u[y] + first * floor_du[y],
                    floor_v[y] + first * floor_dv[y], floor_du[y], floor_dv[y])
            end
        end
        previous = current
    end

    print_stat(fps_label, VIEW_Y + 3)
    print_stat(cpu0_label, VIEW_Y + 13)
    print_stat(cpu1_label, VIEW_Y + 23)
end

function init()
    cpu_load() -- Prime the per-core counters; the first sample returns nil.
    walls[1] = {load("brick"), load("brick_side")}
    walls[2] = {load("metal"), load("metal_side")}
    ground = load("floor")
    cls(hud)
    render()
end

function update(dt)
    if keyp(1, 1) then os.exit(); return end
    if keyp(3, 5) then px, py, angle = 3.5, 3.5, 0 end -- R
    frames, elapsed = frames + 1, elapsed + dt
    if elapsed >= 0.5 then
        fps_label = "FPS " .. floor(frames / elapsed + 0.5)
        local core0, core1 = cpu_load()
        if core0 ~= nil and core1 ~= nil then
            cpu0_label = "CPU0 " .. floor(core0 + 0.5) .. "%"
            cpu1_label = "CPU1 " .. floor(core1 + 0.5) .. "%"
        end
        frames, elapsed = 0, 0
    end

    local forward, strafe, turn = 0, 0, 0
    -- Matrix coordinates are (row, column), matching input.key.
    if key(2, 3) or key(4, 12) then forward = forward + 1 end -- @ / up
    if key(3, 3) or key(5, 12) then forward = forward - 1 end -- W / down
    if key(3, 2) or key(5, 11) then turn = turn - 1 end -- Q / left
    if key(3, 4) or key(5, 13) then turn = turn + 1 end -- E / right
    if key(2, 2) then strafe = strafe - 1 end -- !
    if key(2, 4) then strafe = strafe + 1 end -- #
    -- Cap pauses and subdivide movement so a slow frame cannot cross a wall.
    dt = min(dt, 0.1)
    local steps = max(1, ceil(dt / 0.02))
    local step = dt / steps
    local speed = forward ~= 0 and strafe ~= 0 and 2 / sqrt(2) or 2
    for _ = 1, steps do
        angle = (angle + turn * 1.9 * step) % (2 * math.pi)
        local dx, dy = cos(angle), sin(angle)
        move((dx * forward - dy * strafe) * speed * step,
            (dy * forward + dx * strafe) * speed * step)
    end
    render()
end

function deinit()
    for _, sprite in ipairs(sprites) do sprite:close() end
    sprites = {}
end
