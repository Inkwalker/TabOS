local rules = require("game")
local draw = require("render")
local sfx = require("sfx")

local game = {}
local fps_label = "FPS: --"
local background_time = 0
local frame_count, frame_time = 0, 0

function init()
    rules.reset(game)
    fps_label = "FPS: --"
    background_time = 0
    frame_count, frame_time = 0, 0
    draw(game, fps_label, background_time)
end

function update(dt)
    if input.keyp(1, 1) then os.exit(); return end
    sfx.update(dt)
    rules.update(game, dt)
    background_time = background_time + dt
    frame_time = frame_time + dt
    frame_count = frame_count + 1

    if frame_time >= 1 then
        local presenter_fps = gfx.presenter_fps()
        fps_label = "FPS: " .. math.floor(frame_count / frame_time + 0.5)
            .. " (" .. math.floor(presenter_fps + 0.5) .. ")"
        frame_count, frame_time = 0, 0
    end

    draw(game, fps_label, background_time)
end

function deinit()
    sfx.stop()
end
