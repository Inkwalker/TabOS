local config = require("config")

local background = gfx.rgb(13, 20, 32)
local bg_red, bg_green, bg_blue = gfx.rgb(background)
local circle_color = gfx.rgb(20, 31, 47)
local shadow = gfx.rgb(7, 11, 18)
local white = gfx.rgb(232, 241, 255)
local ball_red, ball_green, ball_blue = gfx.rgb(white)

local function draw_background(time)
    gfx.cls(background)
    local lanes = math.ceil(config.width / 40)
    local spacing = config.width / lanes
    local spawn_interval = 3
    local start_radius = 64
    local min_lifetime, max_lifetime = 8, 13
    for lane = 0, lanes - 1 do
        local lane_time = time + lane * 0.31
        local latest_spawn = math.floor(lane_time / spawn_interval)
        for offset = 0, math.ceil(max_lifetime / spawn_interval) - 1 do
            local spawn = latest_spawn - offset
            local age = lane_time - spawn * spawn_interval
            -- Use the whole and fractional parts of the spawn hash for position and lifetime.
            local seed = math.sin((spawn * lanes + lane) * 12.9898 + 78.233) * 43758.5453
            local position = (math.floor(seed) % 1024) / 1024
            local x = math.floor((lane + position) * spacing)
            local lifetime = min_lifetime + (max_lifetime - min_lifetime) * (seed % 1)
            local y = math.floor(config.height + start_radius - 15 * age)
            local radius = math.floor(start_radius * (1 - age / lifetime))
            if radius > 0 then
                gfx.circfill(x, y, radius, circle_color)
            end
        end
    end
end

local function draw_ripples(bricks)
    for _, brick in ipairs(bricks) do
        local progress = brick.age / config.ripple_duration
        local x = brick.x + math.floor(config.brick_width / 2)
        local y = brick.y + math.floor(config.brick_height / 2)
        local radius = math.floor(64 * progress)
        local strength = 0.45 * (1 - progress)
        local r, g, b = gfx.rgb(brick.color)
        local color = gfx.rgb(
            math.floor(bg_red + (r - bg_red) * strength),
            math.floor(bg_green + (g - bg_green) * strength),
            math.floor(bg_blue + (b - bg_blue) * strength))
        gfx.circ(x, y, radius, color)
    end
end

local function draw_particles(particles)
    for _, particle in ipairs(particles) do
        local age = particle.age
        local x = math.floor(particle.x + particle.vx * age)
        local y = math.floor(particle.y + particle.vy * age + config.particle_gravity * age * age / 2)
        if x >= 0 and x < config.width and y >= 0 and y < config.height then
            local r, g, b = gfx.rgb(particle.color)
            local base_r, base_g, base_b = gfx.rgb(gfx.pget(x, y))
            local strength = 1 - age / config.particle_duration
            gfx.pset(x, y, gfx.rgb(
                math.floor(base_r + (r - base_r) * strength),
                math.floor(base_g + (g - base_g) * strength),
                math.floor(base_b + (b - base_b) * strength)))
        end
    end
end

return function(game, fps_label, background_time)
    draw_background(background_time)
    draw_particles(game.particles)
    draw_ripples(game.destroyed_bricks)
    for _, segment in ipairs(game.trail) do
        local strength = 0.24 * segment.remaining / config.trail_duration
        local color = gfx.rgb(
            math.floor(bg_red + (ball_red - bg_red) * strength),
            math.floor(bg_green + (ball_green - bg_green) * strength),
            math.floor(bg_blue + (ball_blue - bg_blue) * strength))
        gfx.line(segment.x, segment.y, segment.to_x, segment.to_y, color)
    end
    gfx.print(config.left + 4, 8, ("BRICKS   Lives: %d   Score: %d"):format(game.lives, game.score), white)
    gfx.print(config.right - 4 - #fps_label * 6, 8, fps_label, white)
    local border_color = game.border_flash > 0 and config.colors[3] or config.border_color
    gfx.line(config.left, config.top, config.right, config.top, border_color)
    gfx.line(config.left, config.top, config.left, config.height - 8, border_color)
    gfx.line(config.right, config.top, config.right, config.height - 8, border_color)

    for index, brick in ipairs(game.bricks) do
        local x = brick.x
        if game.board_entry_time < config.board_entry_duration then
            local row = math.floor((index - 1) / config.columns)
            local elapsed = game.board_entry_time - row * config.brick_entry_stagger
            local progress = math.max(0, math.min(1, elapsed / config.brick_entry_duration))
            local direction = row % 2 == 0 and -1 or 1
            x = x + direction * math.floor(config.width * (1 - progress)^3)
        end
        gfx.spr(brick.sprite, x, brick.y)
    end
    for _, brick in ipairs(game.destroyed_bricks) do
        if brick.age < config.shrink_duration then
            local scale = 1 - brick.age / config.shrink_duration
            local w = math.max(1, math.floor(config.brick_width * scale))
            local h = math.max(1, math.floor(config.brick_height * scale))
            local x = brick.x + math.floor((config.brick_width - w) / 2)
            local y = brick.y + math.floor((config.brick_height - h) / 2)
            gfx.rect(x, y, w, h, brick.color)
        end
    end
    local flash_fraction = game.paddle_flash / config.flash_duration
    local shake = math.floor(flash_fraction * math.cos((1 - flash_fraction) * 4 * math.pi) + 0.5)
    gfx.spr(config.paddle_sprite, math.floor(game.paddle_x), config.paddle_y + shake, config.paddle_transparent)
    if game.state == "ready" or game.state == "playing" then
        local x, y = math.floor(game.ball_x), math.floor(game.ball_y)
        gfx.circfill(x, y + 2, config.radius, shadow)
        gfx.circfill(x, y, config.radius, game.ball_flash > 0 and config.ball_flash_color or white)
    end

    local message
    if game.state == "ready" then
        message = "Space to launch"
    elseif game.state == "lost" then
        message = "Game over  /  Space to play again"
    end
    if message then
        gfx.print(math.floor((config.width - #message * 6) / 2), math.floor(config.height / 2), message, white)
    end
    gfx.flip()
end
