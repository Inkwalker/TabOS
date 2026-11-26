local Panel = require("lib.ui.panel")
local Label = require("lib.ui.label")
local Button = require("lib.ui.button")
local OpenWith = {}
OpenWith.__index = OpenWith

function OpenWith.new(request, colors)
    local root = Panel.new({x = 8, y = 8, width = 284, height = 164}, colors.panel, colors.accent)
    root:add(Label.new({x = 8, y = 8, width = 264, height = 8}, "Open With", colors.text))
    root:add(Label.new({x = 8, y = 21, width = 264, height = 8}, request.path:match("[^/]+$"), colors.muted))
    local rows = {}
    for index = 1, 4 do
        local row = root:add(Button.new({x = 8, y = 34 + (index - 1) * 20, width = 268, height = 20},
            nil, nil, {pressed_background = colors.pressed}))
        row.name_label = row:add(Label.new({x = 6, y = 0, width = 162, height = 20}, "", colors.text))
        row.path_label = row:add(Label.new({x = 175, y = 0, width = 90, height = 20}, "", colors.muted))
        rows[index] = row
    end
    local style = {color = colors.accent, pressed_background = colors.pressed}
    local function choice(x, y, width, text, action)
        return root:add(Button.new({x = x, y = y, width = width, height = 22}, text, action, style))
    end
    local previous = choice(8, 114, 46, "Prev")
    local next_page = choice(230, 114, 46, "Next")
    local counter = root:add(Label.new({x = 54, y = 114, width = 176, height = 22}, "", colors.muted, "center"))
    choice(8, 136, 90, "Just Once", {open_choice = "once"})
    choice(98, 136, 88, "Always", {open_choice = "always"})
    choice(186, 136, 90, "Cancel", {cancel_chooser = true})
    return setmetatable({request = request, selected = 1, colors = colors, root = root, rows = rows,
        previous = previous, next_page = next_page, counter = counter}, OpenWith)
end

function OpenWith:key_action(input)
    if input.keyp(1, 1) then return {cancel_chooser = true} end
    if input.keyp(4, 14) then return {open_choice = "once"} end
    local up = input.keyp(4, 12)
    if up or input.keyp(5, 12) then
        local direction = up and -1 or 1
        return {candidate = math.max(1, math.min(#self.request.candidates, self.selected + direction))}
    end
end

function OpenWith:draw()
    local candidates, selected = self.request.candidates, self.selected
    if self.rendered_selection ~= selected then
        local first = ((selected - 1) // 4) * 4 + 1
        for slot, row in ipairs(self.rows) do
            local index = first + slot - 1
            local app = candidates[index]
            row.visible = app ~= nil
            if app then
                if not row.action or row.action.candidate ~= index then row.action = {candidate = index} end
                row.background = index == selected and self.colors.pressed or nil
                row.name_label.text, row.path_label.text = app.name, app.path:match("[^/]+$")
            end
        end
        self.previous.visible, self.next_page.visible = first > 1, first + 4 <= #candidates
        if self.rendered_first ~= first then
            self.previous.action, self.next_page.action = {candidate = first - 4}, {candidate = first + 4}
        end
        self.counter.text = selected .. "/" .. #candidates
        self.rendered_selection, self.rendered_first = selected, first
    end
    return self.root:draw()
end

return OpenWith
