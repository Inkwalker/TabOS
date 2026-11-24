local Button = require("button")
local InputField = require("input_field")
local Label = require("label")

local NewSpriteDialog = {}
NewSpriteDialog.__index = NewSpriteDialog

local x, width, height = 4, 184, 91
local limit_message = "Maximum size is 65,536 pixels"

function NewSpriteDialog.new(y, colors, create, redraw)
    local self = setmetatable({
        y = y, colors = colors, create = create, redraw = redraw,
        fields = {}, captions = {},
        title = Label.new(x + 4, y + 7, 176, "New Sprite", colors.text, "center"),
        message = Label.new(x + 4, y + 43, 176, limit_message, colors.muted, "center"),
    }, NewSpriteDialog)
    local button_colors = {background = colors.button, text = colors.accent, disabled_text = colors.muted}
    for index, name in ipairs({"Width", "Height"}) do
        local left = x + 4 + (index - 1) * 90
        self.captions[index] = Label.new(left, y + 26, 40, name, colors.text)
        self.fields[index] = InputField.new(left + 40, y + 21, 46, 18, button_colors,
            {accept = "%d", max_length = 6})
    end
    self.submit_button = Button.new(x + 4, y + 59, 86, 24, "New Sprite", button_colors, function()
        self:submit()
    end)
    self.cancel_button = Button.new(x + 94, y + 59, 86, 24, "Cancel", button_colors, function()
        self:dismiss()
    end)
    return self
end

function NewSpriteDialog:show()
    self.visible, self.focus = true, 1
    for _, field in ipairs(self.fields) do field:set_value("32") end
    self.fields[1]:select()
    self.message.color = self.colors.muted
    self.message:set_text(limit_message)
    self.redraw()
end

function NewSpriteDialog:dismiss()
    self.visible = false
    self.redraw()
end

local function dimension(field)
    local value = tonumber(field.value)
    if value and value >= 1 and value <= 32767 and #field.value <= 5 then return value end
end

function NewSpriteDialog:submit()
    local sprite_width, sprite_height = dimension(self.fields[1]), dimension(self.fields[2])
    local ok, err
    if sprite_width and sprite_height then
        ok, err = self.create(sprite_width, sprite_height)
    else
        err = "Enter dimensions 1 to 32767"
    end
    if ok then
        self:dismiss()
    else
        self.message.color = self.colors.error
        self.message:set_text(err or "Cannot create sprite")
        self.redraw()
    end
end

function NewSpriteDialog:draw()
    if not self.visible then return end
    gfx.rectfill(x, self.y, width, height, self.colors.panel)
    gfx.rect(x, self.y, width, height, self.colors.accent)
    self.title:draw()
    for index, field in ipairs(self.fields) do
        self.captions[index]:draw()
        field:draw(index == self.focus)
    end
    self.submit_button:draw()
    self.cancel_button:draw()
    self.message:draw()
end

function NewSpriteDialog:press(touch)
    for index, field in ipairs(self.fields) do
        if field:press(touch) then
            self.focus = index
            self.redraw()
            return
        end
    end
    if self.submit_button:press(touch) or self.cancel_button:press(touch) then return end
    if touch.x < x or touch.x >= x + width or touch.y < self.y or touch.y >= self.y + height then
        self:dismiss()
    end
end

function NewSpriteDialog:update(touch)
    if not self.visible then return false end
    if input.keyp(1, 1) then
        self:dismiss()
    elseif touch then
        self:press(touch)
    else
        local tab = input.keyp(3, 1)
        if tab then
            self.focus = 3 - self.focus
            self.fields[self.focus]:select()
        end
        local changed = self.fields[self.focus]:update()
        if changed then
            self.message.color = self.colors.muted
            self.message:set_text(limit_message)
        end
        if input.keyp(4, 14) then
            self:submit()
        elseif changed or tab then
            self.redraw()
        end
    end
    return true
end

return NewSpriteDialog
