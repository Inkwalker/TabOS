local sfx = {}
local tones = {
    wall = {voice = 1, frequency = 330, duration = 0.045, volume = 0.22},
    paddle = {voice = 2, frequency = 440, duration = 0.065, volume = 0.28},
    brick = {voice = 3, frequency = 660, duration = 0.055, volume = 0.24},
}
local remaining = {}

function sfx.play(kind)
    local tone = assert(tones[kind], "unknown collision sound")
    if audio.set_volume(tone.voice, tone.volume)
        and audio.start(tone.voice, tone.frequency, "triangle") then
        remaining[tone.voice] = tone.duration
    end
end

function sfx.update(dt)
    for voice, duration in pairs(remaining) do
        duration = duration - dt
        remaining[voice] = duration
        -- Retry next frame if the audio command queue is full.
        if duration <= 0 and audio.stop(voice) then
            remaining[voice] = nil
        end
    end
end

function sfx.stop()
    for voice in pairs(remaining) do
        if audio.stop(voice) then remaining[voice] = nil end
    end
end

return sfx
