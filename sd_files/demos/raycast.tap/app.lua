-- A compact Wolfenstein-style gfx.tline demo. One map cell is one unit.
local W, H = gfx.width, gfx.height
local HALF_H = H / 2
local TEX = 32
local FOCAL = H / (2 * 0.66) -- Preserve the original vertical field of view.
local PLANE = W / (2 * FOCAL)
local MAX_DISTANCE = 12 -- Camera depth in map cells; also limits DDA traversal.
local MOVE_RESPONSE = 16 -- Velocity approaches its target with a 1/16 second time constant.
local MOUSE_YAW = 0.003 -- Radians per device count.
local FULL_TURN = 2 * math.pi
local BARREL_SIZE = 0.6
local NEAR_DEPTH = 0.05
local SPRITE_KEY = 0xf81f -- Magenta in RGB565.
local floor, ceil, abs = math.floor, math.ceil, math.abs
local min, max, cos, sin, sqrt, exp = math.min, math.max, math.cos, math.sin, math.sqrt, math.exp
local tline, rectfill = gfx.tline, gfx.rectfill
local sspr, clip = gfx.sspr, gfx.clip
local print_text, load_sprite = gfx.print, gfx.load_sprite
local key, keyp = input.key, input.keyp
local read_mouse = input.mouse
local cpu_load = sys.cpu_load
local sort = table.sort
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

-- World-space positions in open cells. Each barrel rests on the floor.
local barrels = {
    {x = 5.5, y = 3.45},
    {x = 7.4, y = 3.8},
    {x = 6.5, y = 1.5},
    {x = 3.5, y = 7.5},
    {x = 10.5, y = 9.5},
    {x = 12.5, y = 14.5},
}
local visible_barrels = {}
for i, object in ipairs(barrels) do object.index = i end

-- Projection depends only on the fixed viewport and field of view.
local row_depth, column_camera_x = {}, {}
-- Reused each frame: wall-to-floor edges and horizontal texture span data.
local floor_top, span_start = {}, {}
local wall_depth = {}
local floor_u, floor_v, floor_du, floor_dv = {}, {}, {}, {}
local FIRST_FLOOR_ROW = ceil(HALF_H + FOCAL * 0.5 / MAX_DISTANCE - 0.5)
local CLIP_TOP = H - FIRST_FLOOR_ROW
local CLIP_BOTTOM = FIRST_FLOOR_ROW - 1
for y = FIRST_FLOOR_ROW, H - 1 do
    row_depth[y] = FOCAL * 0.5 / abs(y + 0.5 - HALF_H)
end
for x = 0, W - 1 do
    column_camera_x[x] = 2 * (x + 0.5) / W - 1
end

local px, py, angle = 3.5, 3.5, 0
local vx, vy = 0, 0
local walls = {}
local ground, ceiling, barrel_sprite
local sprites = {}
local frames, elapsed, fps_label = 0, 0, "FPS --"
local cpu0_label, cpu1_label = "CPU0 --", "CPU1 --"
local ink = gfx.rgb(218, 208, 175)
local distant_ceiling_color = gfx.rgb(45, 49, 55)
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

local function move(step)
    -- A wall cancels velocity into its face while allowing motion along it.
    local next_x = px + vx * step
    if free(next_x, py) then
        px = next_x
    else
        vx = 0
    end
    local next_y = py + vy * step
    if free(px, next_y) then
        py = next_y
    else
        vy = 0
    end
end

local function print_stat(text, y)
    local x = W - #text * 6 - 3
    print_text(x, y, text, ink)
end

local function farther_first(a, b)
    if a.depth == b.depth then return a.index < b.index end
    return a.depth > b.depth
end

local function render_barrels(dir_x, dir_y)
    local count = 0
    for _, object in ipairs(barrels) do
        local dx, dy = object.x - px, object.y - py
        local depth = dx * dir_x + dy * dir_y
        if depth >= NEAR_DEPTH and depth < MAX_DISTANCE then
            local scale = FOCAL / depth
            local side = dy * dir_x - dx * dir_y
            local size = max(1, floor(BARREL_SIZE * scale + 0.5))
            local x = floor(W * 0.5 + side * scale - size * 0.5 + 0.5)
            local y = floor(HALF_H + 0.5 * scale + 0.5) - size
            if x < W and x + size > 0 and y < H and y + size > 0 then
                object.depth, object.size = depth, size
                object.screen_x, object.screen_y = x, y
                count = count + 1
                visible_barrels[count] = object
            end
        end
    end
    for i = #visible_barrels, count + 1, -1 do visible_barrels[i] = nil end
    if count == 0 then return end
    sort(visible_barrels, farther_first)

    for _, object in ipairs(visible_barrels) do
        local x, y, size = object.screen_x, object.screen_y, object.size
        local right = min(W, x + size)
        local first
        -- Draw a scaled sprite per visible run, keeping the full sprite's UVs
        -- when a nearer wall hides part of it.
        for column = max(0, x), right do
            if column < right and object.depth < wall_depth[column] then
                first = first or column
            elseif first then
                clip(first, 0, column - first, H)
                sspr(barrel_sprite, 0, 0, TEX, TEX, x, y, size, size, SPRITE_KEY)
                first = nil
            end
        end
    end
    clip()
end

local function render()
    local dir_x, dir_y = cos(angle), sin(angle)
    local plane_x, plane_y = -dir_y * PLANE, dir_x * PLANE

    -- Clear every frame so walls leaving the view cannot leave stale pixels.
    local last_row = H - 1
    local horizon = floor(HALF_H)
    rectfill(0, 0, W, horizon, distant_ceiling_color)
    rectfill(0, horizon, W, H - horizon, distant_floor_color)
    -- A black far-plane wall closes the view where rays reach the distance cap.
    if CLIP_BOTTOM >= CLIP_TOP then
        rectfill(0, CLIP_TOP, W, CLIP_BOTTOM - CLIP_TOP + 1, 0x0000)
    end

    -- The camera sits halfway between floor and ceiling, so mirrored rows
    -- share the same depth and world-space texture coordinates.
    for y = FIRST_FLOOR_ROW, last_row do
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
        wall_depth[x] = MAX_DISTANCE
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
            wall_depth[x] = distance
            local wall_u = side == 1 and py + distance * ray_y or px + distance * ray_x
            wall_u = floor((wall_u - floor(wall_u)) * TEX)
            if (side == 1 and ray_x > 0) or (side == 2 and ray_y < 0) then
                wall_u = TEX - 1 - wall_u
            end
            local projected = FOCAL / distance
            local bottom = min(last_row, ceil(HALF_H + projected * 0.5 - 0.5) - 1)
            local top = last_row - bottom
            floor_top[x] = max(FIRST_FLOOR_ROW, bottom + 1)
            if bottom >= top then
                -- Start UV at the visible pixel, preserving scale near walls.
                local v = ((top + 0.5 - HALF_H) / projected + 0.5) * TEX
                tline(walls[material][side], x, top, x, bottom, wall_u, v, 0, TEX / projected)
            end
        end
    end

    -- Sweep wall bottoms to find visible floor spans. Symmetric wall edges
    -- let the same spans draw the ceiling in reverse row order.
    local previous = H
    for x = 0, W do
        local current = x < W and min(H, floor_top[x]) or H
        if current < previous then
            for y = current, previous - 1 do span_start[y] = x end
        elseif current > previous then
            for y = previous, current - 1 do
                local first = span_start[y]
                local du, dv = floor_du[y], floor_dv[y]
                local u, v = floor_u[y] + first * du, floor_v[y] + first * dv
                tline(ground, first, y, x - 1, y, u, v, du, dv)
                local ceiling_y = last_row - y
                tline(ceiling, first, ceiling_y, x - 1, ceiling_y, u, v, du, dv)
            end
        end
        previous = current
    end

    render_barrels(dir_x, dir_y)
    print_stat(fps_label, 3)
    print_stat(cpu0_label, 13)
    print_stat(cpu1_label, 23)
end

function init()
    cpu_load() -- Prime the per-core counters; the first sample returns nil.
    walls[1] = {load("brick"), load("brick_side")}
    walls[2] = {load("metal"), load("metal_side")}
    ground = load("floor")
    ceiling = load("ceiling")
    barrel_sprite = load("barrel")
    render()
end

function update(dt)
    if keyp(1, 1) then os.exit(); return end
    if keyp(3, 5) then -- R
        px, py, angle = 3.5, 3.5, 0
        vx, vy = 0, 0
    elseif read_mouse then
        local mouse = read_mouse()
        if mouse.connected then
            -- The reports already contain the displacement since the last poll.
            angle = (angle + mouse.dx * MOUSE_YAW) % FULL_TURN
        end
    end
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
    local response = 1 - exp(-MOVE_RESPONSE * step)
    local speed = forward ~= 0 and strafe ~= 0 and 2 / sqrt(2) or 2
    for _ = 1, steps do
        angle = (angle + turn * 1.9 * step) % FULL_TURN
        local dx, dy = cos(angle), sin(angle)
        local target_x = (dx * forward - dy * strafe) * speed
        local target_y = (dy * forward + dx * strafe) * speed
        vx = vx + (target_x - vx) * response
        vy = vy + (target_y - vy) * response
        move(step)
    end
    render()
end

function deinit()
    for _, sprite in ipairs(sprites) do sprite:close() end
    sprites = {}
end
