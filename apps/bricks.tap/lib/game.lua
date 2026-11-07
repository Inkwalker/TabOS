local config = require("config")

local rules = {}

local function reset_ball(game)
    game.state = "ready"
    game.launch_pending = false
    game.paddle_x = (config.width - config.paddle_width) / 2
    game.paddle_velocity = 0
    game.paddle_flash, game.border_flash = 0, 0
    game.ball_x = game.paddle_x + config.paddle_width / 2
    game.ball_y = config.paddle_y - config.radius - 1
end

local function fill_board(game)
    game.bricks = {}
    game.board_entry_time = 0
    for row, color in ipairs(config.colors) do
        for column = 1, config.columns do
            local x = config.brick_left + (column - 1) * (config.brick_width + config.gap)
            local y = config.top + 14 + (row - 1) * (config.brick_height + config.gap)
            game.bricks[#game.bricks + 1] = {
                x = x, y = y, right = x + config.brick_width, bottom = y + config.brick_height, color = color,
            }
        end
    end
end

function rules.reset(game)
    game.destroyed_bricks, game.trail, game.particles = {}, {}, {}
    game.lives, game.score, game.ball_speed = 3, 0, config.ball_speed
    fill_board(game)
    reset_ball(game)
end

local function spawn_impact(game, x, y, nx, ny, color)
    for _ = 1, 5 do
        local speed = 60 + math.random() * 60
        local spread = (math.random() - 0.5) * 60
        game.particles[#game.particles + 1] = {
            x = x, y = y, age = 0, color = color,
            vx = nx * speed - ny * spread,
            vy = ny * speed + nx * spread,
        }
    end
end

local function move_ball(game, dt)
    local previous_x, previous_y = game.ball_x, game.ball_y
    game.ball_x, game.ball_y = game.ball_x + game.vx * dt, game.ball_y + game.vy * dt

    if game.ball_x < config.left + config.radius then
        game.ball_x, game.vx = config.left + config.radius, math.abs(game.vx)
        game.border_flash = config.flash_duration
        spawn_impact(game, config.left, game.ball_y, 1, 0, config.colors[3])
    elseif game.ball_x > config.right - config.radius then
        game.ball_x, game.vx = config.right - config.radius, -math.abs(game.vx)
        game.border_flash = config.flash_duration
        spawn_impact(game, config.right, game.ball_y, -1, 0, config.colors[3])
    end
    if game.ball_y < config.top + config.radius then
        game.ball_y, game.vy = config.top + config.radius, math.abs(game.vy)
        game.border_flash = config.flash_duration
        spawn_impact(game, game.ball_x, config.top, 0, 1, config.colors[3])
    end

    if game.vy > 0
        and previous_y + config.radius <= config.paddle_y and game.ball_y + config.radius >= config.paddle_y
        and game.ball_x + config.radius > game.paddle_x
        and game.ball_x - config.radius < game.paddle_x + config.paddle_width then
        local offset = (game.ball_x - game.paddle_x) / config.paddle_width * 2 - 1
        local angle = math.max(-1, math.min(1, offset)) * math.pi / 3
        game.ball_y = config.paddle_y - config.radius
        game.vx, game.vy = game.ball_speed * math.sin(angle), -game.ball_speed * math.cos(angle)
        game.paddle_flash = config.flash_duration
    end

    for index, brick in ipairs(game.bricks) do
        if game.ball_x + config.radius > brick.x and game.ball_x - config.radius < brick.right
            and game.ball_y + config.radius > brick.y and game.ball_y - config.radius < brick.bottom then
            if previous_x + config.radius <= brick.x or previous_x - config.radius >= brick.right then
                local from_left = previous_x + config.radius <= brick.x
                local hit_y = math.max(brick.y, math.min(brick.bottom, game.ball_y))
                spawn_impact(game, from_left and brick.x or brick.right, hit_y, from_left and -1 or 1, 0, brick.color)
                game.ball_x, game.vx = previous_x, -game.vx
            else
                local from_above = game.vy >= 0
                local hit_x = math.max(brick.x, math.min(brick.right, game.ball_x))
                spawn_impact(game, hit_x, from_above and brick.y or brick.bottom, 0, from_above and -1 or 1, brick.color)
                game.ball_y, game.vy = previous_y, -game.vy
            end
            table.remove(game.bricks, index)
            brick.age = 0
            game.destroyed_bricks[#game.destroyed_bricks + 1] = brick
            game.score = game.score + 10
            local boost = config.brick_speed_multiplier
            game.ball_speed = game.ball_speed * boost
            game.vx, game.vy = game.vx * boost, game.vy * boost
            if #game.bricks == 0 then
                fill_board(game)
                game.trail = {}
                reset_ball(game)
            end
            return
        end
    end

    if game.ball_y - config.radius >= config.height then
        game.lives = game.lives - 1
        if game.lives == 0 then
            game.state = "lost"
        else
            reset_ball(game)
        end
    end
end

local function move_paddle(game, direction, dt)
    local target = direction * config.paddle_speed
    local change = config.paddle_acceleration * dt
    local difference = target - game.paddle_velocity
    game.paddle_velocity = game.paddle_velocity + math.max(-change, math.min(change, difference))

    local next_x = game.paddle_x + game.paddle_velocity * dt
    game.paddle_x = math.max(config.left, math.min(config.right - config.paddle_width, next_x))
    if game.paddle_x ~= next_x then
        game.paddle_velocity = 0
    end
end

function rules.update(game, dt)
    input.update()
    local space = input.txt():find(" ", 1, true)
    game.board_entry_time = math.min(config.board_entry_duration, game.board_entry_time + dt)
    for index = #game.trail, 1, -1 do
        local segment = game.trail[index]
        segment.remaining = segment.remaining - dt
        if segment.remaining <= 0 then
            table.remove(game.trail, index)
        end
    end
    for index = #game.destroyed_bricks, 1, -1 do
        local brick = game.destroyed_bricks[index]
        brick.age = brick.age + dt
        if brick.age >= config.ripple_duration then
            table.remove(game.destroyed_bricks, index)
        end
    end
    for index = #game.particles, 1, -1 do
        local particle = game.particles[index]
        particle.age = particle.age + dt
        if particle.age >= config.particle_duration then
            table.remove(game.particles, index)
        end
    end
    if game.state == "lost" then
        if space then
            rules.reset(game)
        end
        return
    end

    -- The top row starts with Esc, then 1 through +.
    local direction = (input.key(1, 13) and 1 or 0) - (input.key(1, 2) and 1 or 0)
    if game.state == "ready" then
        if space then
            game.launch_pending = true
        end
        if game.launch_pending and game.board_entry_time >= config.board_entry_duration then
            game.vx, game.vy = game.ball_speed * 0.5, -game.ball_speed * math.sqrt(0.75)
            game.state = "playing"
            game.launch_pending = false
        elseif direction == 0 and game.paddle_velocity == 0 then
            return
        end
    end

    -- Short steps keep the ball from skipping over a paddle or brick on a slow frame.
    dt = math.min(dt, 0.05)
    local steps = math.max(1, math.ceil(dt * math.max(240, game.ball_speed / config.radius)))
    local step = dt / steps
    local trail_x, trail_y = math.floor(game.ball_x), math.floor(game.ball_y)
    for _ = 1, steps do
        game.paddle_flash = math.max(0, game.paddle_flash - step)
        game.border_flash = math.max(0, game.border_flash - step)
        move_paddle(game, direction, step)
        if game.state == "ready" then
            game.ball_x = game.paddle_x + config.paddle_width / 2
        else
            move_ball(game, step)
            if game.state ~= "playing" then
                break
            end
        end
    end
    if game.state == "playing" then
        local x, y = math.floor(game.ball_x), math.floor(game.ball_y)
        if x ~= trail_x or y ~= trail_y then
            game.trail[#game.trail + 1] = {
                x = trail_x, y = trail_y, to_x = x, to_y = y, remaining = config.trail_duration,
            }
        end
    end
end

return rules
