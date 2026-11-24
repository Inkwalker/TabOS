local Button = require("button")
local IconButton = require("icon_button")
local Label = require("label")

local FileMenu = {}
FileMenu.__index = FileMenu

local menu_x = 4
local content_x = menu_x + 4

function FileMenu.new(toolbar_height, colors, actions, redraw)
    local icon = assert(gfx.load_sprite(os.path("spr/menu.png")))
    local self = setmetatable({icon = icon, y = toolbar_height, colors = colors, redraw = redraw}, FileMenu)
    local button_colors = {background = colors.button, text = colors.accent, disabled_text = colors.muted}

    local entries = {width = 84, height = 108, buttons = {}}
    for index, entry in ipairs({{"New Sprite", actions.new_sprite},
        {"Open", actions.open}, {"Save", actions.save},
        {"Save As", actions.save_as}, {"Exit", actions.exit}}) do
        entries.buttons[index] = Button.new(content_x, toolbar_height + 4 + (index - 1) * 20, 76, 18,
            entry[1], button_colors, function()
                self.popup = nil
                entry[2]()
            end)
    end
    self.entries = entries
    self.button = IconButton.new(menu_x, 2, 20, 20, icon, {background = colors.button}, function()
        self.popup = entries
    end)

    local prompt = {width = 148, height = 44, buttons = {},
        title = Label.new(content_x, toolbar_height + 7, 140, "", colors.text, "center")}
    prompt.buttons[1] = Button.new(content_x, toolbar_height + 22, 68, 18, "Replace", button_colors, function()
        local replace = self.replace
        self.popup, self.replace = nil, nil
        replace()
        redraw()
    end)
    prompt.buttons[2] = Button.new(80, toolbar_height + 22, 68, 18, "Cancel", button_colors, function()
        self:dismiss()
    end)
    self.prompt = prompt

    return self
end

function FileMenu:draw()
    self.button:draw()
    local popup = self.popup
    if not popup then return end
    gfx.rectfill(menu_x, self.y, popup.width, popup.height, self.colors.panel)
    gfx.rect(menu_x, self.y, popup.width, popup.height, self.colors.accent)
    if popup.title then popup.title:draw() end
    for _, button in ipairs(popup.buttons) do button:draw() end
end

function FileMenu:press(touch, can_save)
    if not self.button:press(touch) then return false end
    self.entries.buttons[3].enabled = can_save
    self.entries.buttons[4].enabled = can_save
    return true
end

function FileMenu:confirm_replace(name, replace)
    self.prompt.title:set_text("Replace " .. name .. "?")
    self.popup, self.replace = self.prompt, replace
end

function FileMenu:dismiss()
    self.popup, self.replace = nil, nil
    self.redraw()
end

function FileMenu:update_popup(touch)
    local popup = self.popup
    if not popup then return false end
    if input.keyp(1, 1) then
        self:dismiss()
    elseif touch then
        for _, button in ipairs(popup.buttons) do
            if button:press(touch) then return true end
        end
        if touch.x < menu_x or touch.x >= menu_x + popup.width
            or touch.y < self.y or touch.y >= self.y + popup.height then
            self:dismiss()
        end
    end
    return true
end

function FileMenu:close()
    self.icon:close()
end

return FileMenu
