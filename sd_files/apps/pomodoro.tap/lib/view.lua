local Button = require("button")
local IconButton = require("icon_button")
local Label = require("label")
local Countdown = require("countdown")
local colors = require("theme")

local View = {}
View.__index = View

local header_height = 20
local margin = 2
local gap = 2
local button_height = 23
local line_height = 8
local icon_key = gfx.rgb(255, 0, 255)
local status_labels = {ready = "Ready to start", running = "Running", paused = "Paused"}
local primary_labels = {ready = "Start", running = "Pause", paused = "Resume"}

function View.new(modes, duration_keys, chime_keys, focus, round_size)
    local content_top = header_height + margin
    local content_right = gfx.width - margin
    local content_bottom = gfx.height - margin
    local content_width = content_right - margin
    local actions_y = content_bottom - button_height
    local panel_y = content_top + button_height + gap
    local panel_bottom = actions_y - gap
    local status_y = panel_bottom - 24
    local message_y = content_bottom - line_height
    local row_height = (message_y - content_top - #modes * gap) // #modes

    local icon = assert(gfx.load_sprite(os.path("icon.png")))
    local gear = assert(gfx.load_sprite(os.path("spr/gear.png")))
    local title_x, title_y = margin + icon.width + 6, (header_height - line_height) // 2 + 2
    local header_button_height = 18
    local done_width = 40
    local settings = IconButton.new(content_right - header_button_height, margin, header_button_height, header_button_height,
        gear, icon_key, "settings")
    local done = Button.new(content_right - done_width, margin, done_width, header_button_height, "Done", "settings")
    local skip = Button.new(content_right - 72, actions_y, 72, button_height, "Skip", "skip")
    local reset = Button.new(skip.x - gap - 72, actions_y, 72, button_height, "Reset", "reset")
    local primary = Button.new(margin, actions_y, reset.x - gap - margin, button_height, "Start", "toggle")
    local view = setmetatable({
        focus = focus,
        round_size = round_size,
        content_width = content_width,
        panel_y = panel_y,
        panel_height = panel_bottom - panel_y,
        progress_y = panel_bottom - 11,
        row_height = row_height,
        settings = settings,
        primary = primary,
        reset = reset,
        skip = skip,
        timer_buttons = {settings, primary, reset, skip},
        settings_buttons = {done},
        done = done,
        tabs = {},
        settings_rows = {},
        icon = icon,
        title = Label.new(title_x, title_y, "Pomodoro", colors.text),
        countdown = Countdown.new(2 * margin, panel_y + margin,
            content_width - 2 * margin, status_y - panel_y - 2 * margin),
        status = Label.new(margin + 10, status_y, "", colors.muted),
        rounds = Label.new(content_right - 111, status_y, "", colors.muted),
        settings_title = Label.new(title_x, title_y, "Timer settings", colors.text),
        settings_message = Label.new(margin, message_y, "", colors.muted),
    }, View)

    local tabs_width = content_width - (#modes - 1) * gap
    for index, name in ipairs(modes) do
        local left = (index - 1) * tabs_width // #modes
        local right = index * tabs_width // #modes
        local tab = Button.new(margin + left + (index - 1) * gap, content_top,
            right - left, button_height, name, "mode")
        tab.index = index
        view.tabs[index] = tab
        view.timer_buttons[#view.timer_buttons + 1] = tab

        local y = content_top + (index - 1) * (row_height + gap)
        local button_y = y + (row_height - 25) // 2
        local label_y = y + (row_height - line_height) // 2
        local minus = Button.new(content_right - 115, button_y, 28, 25, "-", "adjust")
        local plus = Button.new(content_right - 39, button_y, 28, 25, "+", "adjust")
        local chime_width = 42
        local chime = Button.new(minus.x - gap - chime_width, button_y, chime_width, 25, "Chime", "toggle_chime")
        minus.index, minus.step = index, -1
        plus.index, plus.step = index, 1
        chime.index = index
        view.settings_rows[index] = {
            y = y,
            duration_key = duration_keys[index],
            chime_key = chime_keys[index],
            name = Label.new(margin + 10, label_y, name, colors.text),
            minutes = Label.new(content_right - 81, label_y, "", colors.text),
            chime = chime,
            minus = minus,
            plus = plus,
        }
        view.settings_buttons[#view.settings_buttons + 1] = chime
        view.settings_buttons[#view.settings_buttons + 1] = minus
        view.settings_buttons[#view.settings_buttons + 1] = plus
    end

    return view
end

function View:draw_header(settings_open, pressed)
    gfx.spr(self.icon, margin, (header_height - self.icon.height) // 2 + 1, icon_key)
    if settings_open then
        self.settings_title:draw()
        self.done:draw(pressed == self.done, colors.focus, colors.background)
    else
        self.title:draw()
        self.settings:draw(pressed == self.settings, colors.background)
    end
end

function View:draw_timer(timer, pressed)
    local accent = timer.mode == self.focus and colors.focus or colors.rest
    gfx.cls(colors.background)
    self:draw_header(false, pressed)
    for index, tab in ipairs(self.tabs) do
        local selected = index == timer.mode
        tab:draw(pressed == tab, colors.panel, selected and accent or colors.muted, selected and accent or nil)
    end

    gfx.rectfill(margin, self.panel_y, self.content_width, self.panel_height, colors.panel)
    self.countdown:draw()
    self.status.text = timer.notice or status_labels[timer.status]
    self.status:draw()
    self.rounds.text = string.format("Focus %d/%d", timer.completed, self.round_size)
    self.rounds:draw()
    local track_width = self.content_width - 20
    local dot_radius = 2
    local last_dot_x = self.status.x + track_width - 1 - dot_radius
    for index = 1, self.round_size do
        gfx.circfill(last_dot_x - (self.round_size - index) * 10, self.rounds.y + 3, dot_radius,
            index <= timer.completed and colors.focus or colors.track)
    end
    gfx.rectfill(self.status.x, self.progress_y, track_width, 3, colors.track)
    local progress = math.min(track_width, math.ceil(track_width * timer.seconds / timer.duration))
    if progress > 0 then gfx.rectfill(self.status.x, self.progress_y, progress, 3, accent) end

    self.primary.text = primary_labels[timer.status] or "Start"
    self.primary:draw(pressed == self.primary, accent, colors.background)
    self.reset:draw(pressed == self.reset, colors.panel, colors.text)
    self.skip:draw(pressed == self.skip, colors.panel, colors.text)
end

function View:draw_settings(config, settings_error, pressed)
    gfx.cls(colors.background)
    self:draw_header(true, pressed)
    for _, row in ipairs(self.settings_rows) do
        gfx.rectfill(margin, row.y, self.content_width, self.row_height, colors.panel)
        row.name:draw()
        row.minutes.text = string.format("%2d min", config[row.duration_key])
        row.minutes:draw()
        local chime_on = config[row.chime_key]
        row.chime:draw(pressed == row.chime, chime_on and colors.rest or colors.background,
            chime_on and colors.background or colors.muted)
        row.minus:draw(pressed == row.minus, colors.background, colors.text)
        row.plus:draw(pressed == row.plus, colors.background, colors.text)
    end
    self.settings_message.text = settings_error or "Durations apply when a new timer starts."
    self.settings_message:draw()
end

return View
