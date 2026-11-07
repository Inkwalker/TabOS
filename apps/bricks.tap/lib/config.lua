local width, height = gfx.width, gfx.height
local left, right, top = 4, width - 4, 4
local paddle_width, paddle_height = math.floor(width / 9), 6
local paddle_y = height - 8
local paddle_speed = width * 0.56
local paddle_acceleration = paddle_speed / 0.12
local flash_duration = 0.12
local shrink_duration = 0.09
local trail_duration = 1.0
local radius = 3
local ball_speed = height * 0.544
local columns, gap, brick_height = 10, 5, 8
local brick_width = math.floor((right - left - (columns - 1) * gap) / columns)
local brick_left = math.floor((width - columns * brick_width - (columns - 1) * gap) / 2)
local colors = {
    gfx.rgb(250, 103, 117),
    gfx.rgb(255, 169, 92),
    gfx.rgb(249, 220, 111),
    gfx.rgb(105, 225, 180),
    gfx.rgb(100, 172, 255),
}
local brick_entry_duration, brick_entry_stagger = 0.45, 0.05

return {
    width = width,
    height = height,
    left = left,
    right = right,
    top = top,
    paddle_width = paddle_width,
    paddle_height = paddle_height,
    paddle_y = paddle_y,
    paddle_speed = paddle_speed,
    paddle_acceleration = paddle_acceleration,
    flash_duration = flash_duration,
    shrink_duration = shrink_duration,
    ripple_duration = 0.42,
    particle_duration = 0.48,
    particle_gravity = 220,
    border_color = gfx.rgb(66, 89, 114),
    trail_duration = trail_duration,
    radius = radius,
    ball_speed = ball_speed,
    brick_speed_multiplier = 1.01,
    columns = columns,
    gap = gap,
    brick_height = brick_height,
    brick_width = brick_width,
    brick_left = brick_left,
    brick_entry_duration = brick_entry_duration,
    brick_entry_stagger = brick_entry_stagger,
    board_entry_duration = brick_entry_duration + (#colors - 1) * brick_entry_stagger,
    colors = colors,
}
