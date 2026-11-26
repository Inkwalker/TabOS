local View = require("view")

local focus, short_break, long_break = 1, 2, 3
local round_size = 4
local modes = {"Focus", "Short break", "Long break"}
local duration_keys = {"focus_minutes", "short_break_minutes", "long_break_minutes"}
local chime_keys = {"focus_chime", "short_break_chime", "long_break_chime"}
local config_path = os.path("config.ltab")
local config, settings_error
local mode = focus
local duration, remaining
local completed = 0
local status = "ready"
local notice, chime

local settings_open = false
local touch_held, pressed, contact_id = false, nil, nil

local view = View.new(modes, duration_keys, chime_keys, focus, round_size)

local function select_mode(next_mode)
    mode = next_mode
    duration = config[duration_keys[mode]] * 60
    remaining = duration
    status, notice = "ready", nil
    if mode == focus and completed == round_size then completed = 0 end
end

local function advance(finished)
    local previous = mode
    if mode == focus then
        if finished then completed = completed + 1 end
        select_mode(completed == round_size and long_break or short_break)
    else
        select_mode(focus)
    end
    if finished then
        notice = modes[previous] .. " complete"
        if chime and config[chime_keys[previous]] then audio.play(nil, chime) end
    end
end

local function elapse(seconds)
    if status == "running" then
        remaining = remaining - seconds
        if remaining <= 0 then advance(true) end
    end
end

local function save_setting(key, value)
    local previous = config[key]
    config[key] = value
    if not fs.write_table(config_path, config) then
        config[key] = previous
        settings_error = "Could not save timer settings."
        return false
    end
    settings_error = nil
    return true
end

local function activate(button)
    local action, index, step = button.action, button.index, button.step
    if action == "settings" then
        settings_open = not settings_open
    elseif action == "toggle" then
        status = status == "running" and "paused" or "running"
        notice = nil
    elseif action == "reset" then
        select_mode(mode)
    elseif action == "skip" then
        advance(false)
    elseif action == "mode" and index ~= mode then
        select_mode(index)
    elseif action == "toggle_chime" then
        local key = chime_keys[index]
        save_setting(key, not config[key])
    elseif action == "adjust" then
        local key = duration_keys[index]
        local previous = config[key]
        local minutes = math.max(1, math.min(99, previous + step))
        if minutes == previous or not save_setting(key, minutes) then return end
        if index == mode and status == "ready" then
            duration = minutes * 60
            remaining = duration
        end
    end
end

local function update_touch(contacts)
    if #contacts == 0 then
        local button = pressed
        touch_held, pressed, contact_id = false, nil, nil
        return button
    end

    local contact = contacts[1]
    if not touch_held and #contacts == 1 then
        for _, button in ipairs(settings_open and view.settings_buttons or view.timer_buttons) do
            if button:contains(contact) then
                pressed, contact_id = button, contact.id
                break
            end
        end
    elseif pressed and (#contacts ~= 1 or contact.id ~= contact_id or not pressed:contains(contact)) then
        pressed = nil
    end
    touch_held = true
end

local function draw()
    if settings_open then
        view:draw_settings(config, settings_error, pressed)
    else
        view:draw_timer({
            mode = mode, seconds = math.ceil(remaining), duration = duration,
            completed = completed, status = status, notice = notice,
        }, pressed)
    end
end

function init(saved)
    config = assert(fs.read_table(config_path))
    for _, key in ipairs(duration_keys) do
        local value = math.tointeger(config[key])
        assert(type(config[key]) == "number" and value and value >= 1 and value <= 99,
            config_path .. ": " .. key .. " must be an integer from 1 to 99")
    end
    for _, key in ipairs(chime_keys) do
        if config[key] == nil then config[key] = true end
        assert(type(config[key]) == "boolean", config_path .. ": " .. key .. " must be a boolean")
    end
    chime = audio.load(os.path("sfx/complete.wav"))
    if saved then
        mode, duration, remaining = saved.mode, saved.duration, saved.remaining
        completed, status, notice = saved.completed, saved.status, saved.notice
        if status == "running" then status = "paused" end
    end
    if status == "ready" then
        duration = config[duration_keys[mode]] * 60
        remaining = duration
    end
    view.countdown:update(math.ceil(remaining), 0, true)
    draw()
end

function update(dt)
    local previous_status, previous_pressed = status, pressed
    elapse(dt)
    if input.keyp(1, 1) then
        os.suspend()
        return
    end

    local button = update_touch(input.touch())
    local text = input.txt()
    if not settings_open and text:find(" ", 1, true) then
        button = view.primary
        pressed = nil
    end
    if button then activate(button) end
    local countdown_changed = view.countdown:update(math.ceil(remaining), dt, not settings_open)
    if button or status ~= previous_status or countdown_changed or pressed ~= previous_pressed then
        draw()
    end
end

function save_state()
    return {
        mode = mode, duration = duration, remaining = remaining,
        completed = completed, status = status == "running" and "paused" or status, notice = notice,
    }
end
