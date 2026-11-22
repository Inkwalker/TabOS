local width, height = gfx.width, gfx.height
local left, right, top = 4, width - 4, 4
local shadow_height = 2
local paddle_sprite = assert(gfx.load_sprite(os.path("spr/paddle.png")))
local paddle_width, paddle_height = paddle_sprite.width, paddle_sprite.height - shadow_height
local paddle_y = height - paddle_sprite.height
local paddle_speed = width * 0.56
local paddle_acceleration = paddle_speed / 0.12
local flash_duration = 0.12
local shrink_duration = 0.09
local trail_duration = 1.0
local radius = 3
local ball_speed = height * 0.544
local brick_sprites, colors = {}, {}
for row = 1, 5 do
    local sprite = assert(gfx.load_sprite(os.path(("spr/brick_%d.png"):format(row))))
    brick_sprites[row] = sprite
    colors[row] = sprite:pget(math.floor(sprite.width / 2), math.floor((sprite.height - shadow_height) / 2))
end
local brick_width, brick_height = brick_sprites[1].width, brick_sprites[1].height - shadow_height
assert(paddle_height > 0 and brick_height > 0, "sprites must be taller than their shadows")
for _, sprite in ipairs(brick_sprites) do
    assert(sprite.width == brick_width and sprite.height - shadow_height == brick_height,
        "brick sprites must have matching dimensions")
end
local gap = 5
local columns = math.floor((right - left + gap) / (brick_width + gap))
assert(columns > 0 and paddle_width <= right - left, "sprites must fit the playfield")
local brick_left = math.floor((width - columns * brick_width - (columns - 1) * gap) / 2)
local brick_entry_duration, brick_entry_stagger = 0.45, 0.05

return {
    width = width,
    height = height,
    left = left,
    right = right,
    top = top,
    paddle_width = paddle_width,
    paddle_sprite = paddle_sprite,
    paddle_transparent = gfx.rgb(255, 0, 255),
    paddle_height = paddle_height,
    paddle_y = paddle_y,
    paddle_speed = paddle_speed,
    paddle_acceleration = paddle_acceleration,
    flash_duration = flash_duration,
    ball_flash_color = gfx.rgb(255, 210, 64),
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
    brick_sprites = brick_sprites,
    brick_left = brick_left,
    brick_top = top + 18,
    brick_entry_duration = brick_entry_duration,
    brick_entry_stagger = brick_entry_stagger,
    board_entry_duration = brick_entry_duration + (#colors - 1) * brick_entry_stagger,
    colors = colors,
}
