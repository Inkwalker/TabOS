local DialogManager = {}
DialogManager.__index = DialogManager

local function dim_background()
    gfx.clip()
    gfx.fill_pattern(0xA5A5) -- Cover half the pixels with black.
    gfx.rectfill(0, 0, gfx.width, gfx.height, 0)
    gfx.fill_pattern()
end

function DialogManager.new()
    return setmetatable({stack = {}}, DialogManager)
end

-- Launcher dialogs stay on the stack while the app scope is visible.
function DialogManager:push(dialog, scope)
    self.stack[#self.stack + 1] = {dialog = dialog, scope = scope}
end

local function find_top(self, scope)
    for index = #self.stack, 1, -1 do
        local entry = self.stack[index]
        if entry.scope == scope then return entry.dialog, index end
    end
end

function DialogManager:top(scope)
    local dialog = find_top(self, scope)
    return dialog
end

function DialogManager:pop(scope)
    local dialog, index = find_top(self, scope)
    if dialog then table.remove(self.stack, index) end
    return dialog
end

function DialogManager:draw(scope)
    local targets
    local dimmed = false
    for _, entry in ipairs(self.stack) do
        if entry.scope == scope then
            if not dimmed then
                dim_background()
                dimmed = true
            end
            targets = entry.dialog:draw()
        end
    end
    return targets
end

return DialogManager
