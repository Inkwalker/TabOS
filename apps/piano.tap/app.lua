-- Copy piano.tap to the SD card and run /sd/piano.tap in the recovery shell.
local keys = "1234567890-+"
local note_names = {"C4", "D4", "E4", "F4", "G4", "A4", "B4", "C5", "D5", "E5", "F5", "G5"}
local semitones_from_a4 = {-9, -7, -5, -4, -2, 0, 2, 3, 5, 7, 8, 10}
local notes = {}
local voices = {false, false, false, false, false}
local waveforms = {"triangle", "square", "sawtooth", "noise", "sine"}
local waveform_index = 1

for i, name in ipairs(note_names) do
    notes[i] = {
        name = name,
        key = keys:sub(i, i),
        frequency = 440 * 2 ^ (semitones_from_a4[i] / 12),
    }
end

local cpu_label = "CPU0: --"
local cpu_elapsed = 0
local key_width = math.floor((gfx.width - 16) / #notes)
local piano_x = math.floor((gfx.width - key_width * #notes) / 2)
local piano_y = gfx.height - 72
local background = gfx.rgb(12, 19, 29)
local text_color = gfx.rgb(200, 231, 218)
local key_color = gfx.rgb(232, 237, 224)
local active_color = gfx.rgb(93, 224, 167)

local function draw()
    gfx.cls(background)
    gfx.print(8, 8, "PIANO / C MAJOR", text_color)
    gfx.print(gfx.width - #cpu_label * 6 - 8, 8, cpu_label, text_color)
    gfx.print(8, 24, "Wave: " .. waveforms[waveform_index] .. "  [Tab]", text_color)

    for i, note in ipairs(notes) do
        local x = piano_x + (i - 1) * key_width
        gfx.rectfill(x, piano_y, key_width - 2, 72, note.voice and active_color or key_color)
        gfx.print(x + 4, piano_y + 6, note.key, background)
        gfx.print(x + 4, piano_y + 58, note.name, background)
    end

    gfx.flip()
end

local function play_keys()
    local touches = input.touch()
    for i, note in ipairs(notes) do
        -- The twelve piano keys follow Esc on the Tab5 keyboard's top row.
        note.down = input.key(1, i + 1)
        local x = piano_x + (i - 1) * key_width
        for _, touch in ipairs(touches) do
            if touch.x >= x and touch.x < x + key_width - 2
                and touch.y >= piano_y and touch.y < piano_y + 72 then
                note.down = true
                break
            end
        end
    end

    local changed = false
    for voice, note in ipairs(voices) do
        if note and not note.down and audio.stop(voice) then
            note.voice = nil
            voices[voice] = false
            changed = true
        end
    end

    for _, note in ipairs(notes) do
        if note.down and not note.voice then
            for voice, playing in ipairs(voices) do
                if not playing then
                    if audio.start(voice, note.frequency, waveforms[waveform_index]) then
                        voices[voice] = note
                        note.voice = voice
                        changed = true
                    end
                    break
                end
            end
        end
    end
    return changed
end

function init()
    sys.cpu_load()
    draw()
end

function update(dt)
    if input.keyp(1, 1) then os.exit(); return end
    local waveform_changed = input.keyp(3, 1) -- Tab on the Tab5 keyboard.
    if waveform_changed then
        waveform_index = waveform_index % #waveforms + 1
        for voice, note in ipairs(voices) do
            if note then
                audio.set_waveform(voice, waveforms[waveform_index])
            end
        end
    end
    local redraw = play_keys() or waveform_changed
    cpu_elapsed = cpu_elapsed + dt
    if cpu_elapsed >= 0.5 then
        cpu_elapsed = 0
        local core0 = sys.cpu_load()
        if core0 then
            local label = string.format("CPU0: %.0f%%", core0)
            redraw = redraw or label ~= cpu_label
            cpu_label = label
        end
    end
    if redraw then
        draw()
    end
end

function deinit()
    audio.stop()
end
