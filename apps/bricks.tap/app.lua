local rules = require("game")
local draw = require("render")

local game = {}
local fps
local background_time = 0
local frame_count, frame_time = 0, 0

function init()
    rules.reset(game)
    fps = nil
    background_time = 0
    frame_count, frame_time = 0, 0
    draw(game, fps, background_time)
end

function update(dt)
    if input.keyp(1, 1) then os.exit(); return end
    rules.update(game, dt)
    background_time = background_time + dt
    frame_time = frame_time + dt
    frame_count = frame_count + 1

    if frame_time >= 1 then
        fps = math.floor(frame_count / frame_time + 0.5)
        frame_count, frame_time = 0, 0
    end

    draw(game, fps, background_time)
end
