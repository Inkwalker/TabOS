local Files = require("files")
local Encoding = require("filename_encoding")
local Browser = {rows = 10, row_height = 12}
Browser.__index = Browser

function Browser.new(folder, saving)
    local browser = setmetatable({saving = saving, name = "", caret = 1, focus = "list"}, Browser)
    browser:load(folder)
    return browser
end

function Browser:load(folder)
    self.folder = folder
    local entries, err = Files.list(folder)
    self.entries, self.error = entries or {}, err
    self.row, self.top = #self.entries > 0 and 1 or 0, 1
    self.focus = "list"
end

function Browser:select(row)
    self.focus = "list"
    if #self.entries == 0 then return end
    self.row = math.max(1, math.min(#self.entries, row))
    self.top = math.max(1, math.min(self.top, self.row))
    self.top = math.max(self.top, self.row - Browser.rows + 1)
end

function Browser:scroll(top)
    self.top = math.max(1, math.min(top, #self.entries - Browser.rows + 1))
end

function Browser:set_name(name)
    self.name, self.caret, self.focus = name, #name + 1, "name"
end

function Browser:move_caret(step)
    if step < 0 then
        self.caret = Encoding.previous(self.name, self.caret)
    else
        self.caret = Encoding.next(self.name, self.caret)
    end
end

function Browser:edit_name(text)
    local name, caret = self.name, self.caret
    for index = 1, #text do
        local byte = text:sub(index, index)
        if byte == "\b" then
            local start = Encoding.previous(name, caret)
            name, caret = name:sub(1, start - 1) .. name:sub(caret), start
        elseif byte == "\127" then
            local stop = Encoding.next(name, caret)
            name = name:sub(1, caret - 1) .. name:sub(stop)
        elseif byte >= " " and byte <= "~" and #name < 255 * 4 then
            name = name:sub(1, caret - 1) .. byte .. name:sub(caret)
            caret = caret + 1
        end
    end
    self.name, self.caret = name, caret
end

return Browser
