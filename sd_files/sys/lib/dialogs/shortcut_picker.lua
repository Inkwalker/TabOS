local Panel = require("lib.ui.panel")
local Label = require("lib.ui.label")
local Button = require("lib.ui.button")
local ShortcutPicker = {}
ShortcutPicker.__index = ShortcutPicker

local page_size = 5

function ShortcutPicker.new(apps, colors)
    local root = Panel.new({x = 8, y = 8, width = 284, height = 164}, colors.panel, colors.accent)
    root:add(Label.new({x = 8, y = 8, width = 268, height = 8}, "Add Shortcut", colors.text))
    if #apps == 0 then
        root:add(Label.new({x = 8, y = 24, width = 268, height = 20}, "No apps to add from /sd/apps", colors.muted))
    end
    local rows = {}
    local row_style = {color = colors.text, align = "left", padding = 6, pressed_background = colors.pressed}
    for index = 1, math.min(#apps, page_size) do
        local y = 24 + (index - 1) * 20
        rows[index] = root:add(Button.new({x = 8, y = y, width = 268, height = 20}, "", nil, row_style))
    end
    local style = {color = colors.accent, pressed_background = colors.pressed}
    local previous = root:add(Button.new({x = 8, y = 132, width = 56, height = 22}, "Prev", nil, style))
    local next_page = root:add(Button.new({x = 64, y = 132, width = 56, height = 22}, "Next", nil, style))
    local counter = root:add(Label.new({x = 120, y = 132, width = 66, height = 22}, "", colors.muted, "center"))
    root:add(Button.new({x = 186, y = 132, width = 90, height = 22}, "Cancel", {cancel_menu = true}, style))
    local pages = math.max(1, (#apps + page_size - 1) // page_size)
    return setmetatable({root = root, apps = apps, page = 1, pages = pages, rows = rows,
        previous = previous, next_page = next_page, counter = counter}, ShortcutPicker)
end

function ShortcutPicker:key_action(input)
    if input.keyp(1, 1) then return {cancel_menu = true} end
end

function ShortcutPicker:draw()
    if self.rendered_page ~= self.page then
        for slot, row in ipairs(self.rows) do
            local app = self.apps[(self.page - 1) * page_size + slot]
            row.visible = app ~= nil
            if app then
                row:set_text(app.name)
                row.action = {add_shortcut = app}
            end
        end
        self.previous.visible = self.page > 1
        self.previous.action = {shortcut_page = self.page - 1}
        self.next_page.visible = self.page < self.pages
        self.next_page.action = {shortcut_page = self.page + 1}
        self.counter.visible = self.pages > 1
        self.counter.text = self.page .. "/" .. self.pages
        self.rendered_page = self.page
    end
    return self.root:draw()
end

return ShortcutPicker
