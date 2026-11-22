local Paths = require("paths")
local Picker = {}
Picker.__index = Picker

local list_top, row_height, rows = 28, 16, 6
local list_bottom = list_top + row_height * rows

local function inside(path, root)
    return root == "/" or path == root or path:sub(1, #root + 1) == root .. "/"
end

local function display(text)
    return (text:gsub("[^ -~]", function(byte) return string.format("\\x%02X", byte:byte()) end))
end

local function clip(text, width, tail)
    if #text <= width then return text end
    if tail then return "..." .. text:sub(4 - width) end
    return text:sub(1, width - 3) .. "..."
end

function Picker:load(folder)
    local entries, err = Paths.entries(folder)
    self.folder, self.entries, self.read_error = folder, entries or {}, err
    self.first, self.row, self.message = 1, 1, nil
end

function Picker.new(request, context)
    local saving = request.mode == "save"
    local root = assert(Paths.directory(request.root or "/", "/"))
    if saving then
        if root == "/" then root = "/sd" end
        assert(inside(root, "/sd"), "Choose a save folder under /sd")
    end
    local folder = request.directory and Paths.directory(request.directory, root)
    if not folder or not inside(folder, root) then
        folder = root == "/" and "/sd" or root
    end
    local name = saving and request.name or ""
    name = name or ""
    local width = math.min(284, context.width - 16)
    local picker = setmetatable({
        saving = saving, root = root, name = name, caret = #name + 1,
        focus_name = saving, colors = context.colors, input = context.input,
        x = math.floor((context.width - width) / 2), width = width, targets = {},
    }, Picker)
    picker:load(folder)
    return picker
end

function Picker:scroll(first)
    self.first = math.max(1, math.min(first, #self.entries - rows + 1))
    self.row = math.max(self.first, math.min(self.row, self.first + rows - 1))
end

function Picker:select(row)
    self.focus_name, self.message = false, nil
    self.row = math.max(1, math.min(row, #self.entries))
    if self.row < self.first then self:scroll(self.row) end
    if self.row >= self.first + rows then self:scroll(self.row - rows + 1) end
end

function Picker:save_path()
    if self.read_error then return end
    if not Paths.valid_name(self.name) then
        self.message = "Enter a valid filename"
        return
    end
    local _, characters = self.name:gsub("[^\128-\191]", "")
    local _, extra_units = self.name:gsub("[\240-\244]", "")
    if characters + extra_units > 255 then
        self.message = "Filename exceeds 255 characters"
        return
    end
    local path = Paths.join(self.folder, self.name)
    local info, err, code = fs.stat(path)
    if not info then
        if code == 2 then return true, path end
        self.message = err or "Cannot check save destination"
    elseif info.type == "file" then
        local key = Paths.key(path)
        for _, entry in ipairs(self.entries) do
            if entry.type == "file" and entry.key == key then return true, entry.path end
        end
        self:load(self.folder)
        self.message = "Select the existing file by its listed name"
    else
        self.message = "A folder already uses this name"
    end
end

function Picker:activate(row, confirm)
    local entry = self.entries[row]
    if not entry then return end
    self:select(row)
    if entry.type == "dir" then
        self:load(entry.path)
    elseif entry.type == "file" then
        if self.saving then
            self.name, self.caret, self.focus_name = entry.name, #entry.name + 1, true
        elseif confirm then
            local info, err = fs.stat(entry.path)
            if info and info.type == "file" then return true, entry.path end
            self:load(self.folder)
            self.message = err or "File no longer available"
        end
    end
end

local function previous(name, index)
    return name:sub(1, index - 1):find("[^\128-\191][\128-\191]*$") or 1
end

local function following(name, index)
    local _, last = name:find(".[\128-\191]*", index)
    return last and last + 1 or index
end

function Picker:edit_name(text)
    local name, caret = self.name, self.caret
    for char in text:gmatch(".") do
        if char == "\b" then
            local first = previous(name, caret)
            name, caret = name:sub(1, first - 1) .. name:sub(caret), first
        elseif char == "\127" then
            name = name:sub(1, caret - 1) .. name:sub(following(name, caret))
        elseif char >= " " and char <= "~" and #name < 255 * 4 then
            name, caret = name:sub(1, caret - 1) .. char .. name:sub(caret), caret + 1
        end
    end
    self.name, self.caret, self.message = name, caret, nil
end

function Picker:parent()
    if self.folder ~= self.root then self:load(Paths.parent(self.folder)) end
end

function Picker:keys(text)
    local key = self.input.keyp
    if key(4, 12) then self:select(self.row - 1); return end
    if key(5, 12) then self:select(self.row + 1); return end
    if self.saving and key(3, 1) then
        self.focus_name = not self.focus_name
        return
    end
    if self.saving and (self.focus_name or text:find("[ -~]")) then
        self.focus_name = true
        if key(5, 11) then self.caret = previous(self.name, self.caret) end
        if key(5, 13) then self.caret = following(self.name, self.caret) end
        if key(1, 14) then text = text .. "\127" end
        if key(3, 14) and not text:find("\b", 1, true) then text = text .. "\b" end
        if text:find("[ -~\b\127]") then self:edit_name(text) end
        if key(4, 14) then return self:save_path() end
    elseif key(3, 14) or key(5, 11) then
        self:parent()
    elseif key(4, 14) then
        return self:activate(self.row, true)
    end
end

local function hit(target, contact)
    return contact.x >= target.x and contact.x < target.x + target.w
        and contact.y >= target.y and contact.y < target.y + target.h
end

function Picker:update()
    local text = self.input.txt()
    local contacts = self.input.touch()
    if #contacts == 0 then
        local touch = self.touch
        self.touch, self.held = nil, false
        if touch and touch.target then return touch.target.action() end
        return self:keys(text)
    end
    local contact = contacts[1]
    if not self.held and #contacts == 1 then
        self.touch = {id = contact.id, y = contact.y, first = self.first,
            list = contact.x >= self.x and contact.x < self.x + self.width
                and contact.y >= list_top and contact.y < list_bottom}
        for _, target in ipairs(self.targets) do
            if hit(target, contact) then self.touch.target = target; break end
        end
    end
    self.held = true
    local touch = self.touch
    if not touch then return end
    if #contacts ~= 1 or contact.id ~= touch.id then self.touch = nil; return end
    local distance = touch.y - contact.y
    if touch.list and (touch.scrolling or math.abs(distance) >= 6) then
        touch.scrolling, touch.target = true, nil
        self:scroll(touch.first + math.floor(distance / row_height + 0.5))
    elseif touch.target and not hit(touch.target, contact) then
        touch.target = nil
    end
end

function Picker:button(x, y, w, label, action, active, h)
    h = h or 21
    local colors = self.colors
    gfx.rectfill(x, y, w, h - 1, active and colors.pressed or colors.tile)
    gfx.print(x + 4, y + math.floor((h - 8) / 2), label, colors.text)
    self.targets[#self.targets + 1] = {x = x, y = y, w = w, h = h, action = action}
end

function Picker:draw()
    self.targets = {}
    local x, w, colors = self.x, self.width, self.colors
    local title = self.saving and "Save As" or "Open"
    gfx.rectfill(x, 4, w, 172, colors.panel)
    gfx.rect(x, 4, w, 172, colors.accent)
    gfx.print(x + 7, 13, title, colors.accent)
    local path_width = math.floor((w - 118) / 6)
    gfx.print(x + 59, 13, clip(display(self.folder), path_width, true), colors.text)
    if self.folder ~= self.root then
        self:button(x + w - 55, 7, 50, "Parent", function() self:parent() end)
    end

    local list_width = w - 30
    if self.read_error then
        self:button(x + 7, list_top + 18, 54, "Retry", function() self:load(self.folder) end)
    end
    for row = self.first, math.min(#self.entries, self.first + rows - 1) do
        local entry = self.entries[row]
        local label = (entry.type == "dir" and "/ " or "  ") .. display(entry.name)
        self:button(x + 5, list_top + (row - self.first) * row_height, list_width,
            clip(label, math.floor((list_width - 8) / 6)), function()
                return self:activate(row, false)
            end, row == self.row and not self.focus_name, row_height)
    end
    if self.first > 1 then
        self:button(x + w - 22, list_top, 17, "^", function() self:scroll(self.first - rows) end)
    end
    if self.first + rows <= #self.entries then
        self:button(x + w - 22, list_bottom - 21, 17, "v", function() self:scroll(self.first + rows) end)
    end

    local status = self.message or self.read_error or (#self.entries == 0 and "Empty folder")
    if status then
        local color = (self.message or self.read_error) and colors.error or colors.muted
        gfx.print(x + 7, 130, clip(display(status), math.floor((w - 14) / 6)), color)
    end
    local field_width = w - 111
    if self.saving then
        local name = display(self.name)
        local caret = #display(self.name:sub(1, self.caret - 1))
        local visible = math.floor((field_width - 9) / 6)
        local first = math.max(0, caret - visible)
        self:button(x + 5, 150, field_width,
            name == "" and "Filename" or name:sub(first + 1, first + visible),
            function() self.focus_name = true end, self.focus_name)
        if self.focus_name then gfx.rectfill(x + 9 + (caret - first) * 6, 155, 1, 10, colors.accent) end
    end
    self:button(x + w - 102, 150, 44, self.saving and "Save" or "Open", function()
        if self.saving then return self:save_path() end
        return self:activate(self.row, true)
    end)
    self:button(x + w - 54, 150, 49, "Cancel", function() return true end)
end

function Picker:close() end

return Picker
