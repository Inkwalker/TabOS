local Document = require("document")
local Files = require("files")
local History = require("history")
local Tabs = {limit = 8}
Tabs.__index = Tabs

function Tabs.new()
    return setmetatable({items = {}, active = 0, next_untitled = 1, history = History.new()}, Tabs)
end

function Tabs:current()
    return self.items[self.active]
end

function Tabs:activate(index)
    if self.items[index] then self.active = index end
end

function Tabs:cycle(step)
    if #self.items > 0 then self.active = (self.active - 1 + step) % #self.items + 1 end
end

local function append(self, tab)
    self.items[#self.items + 1] = tab
    self.active = #self.items
    return true
end

function Tabs:find(key)
    for index, tab in ipairs(self.items) do
        if tab.key == key then return index end
    end
end

function Tabs:set_path(tab, path)
    tab.path, tab.key, tab.name = path, Files.key(path), path:match("[^/]+$")
    tab.lua_source = tab.name:lower():sub(-4) == ".lua"
    if not tab.lua_source then tab.document.syntax = nil end
    tab.untitled = nil
end

function Tabs:add_document(document, path, number)
    local tab = {document = document}
    if path then
        self:set_path(tab, path)
    else
        number = number or self.next_untitled
        self.next_untitled = math.max(self.next_untitled, number + 1)
        tab.name, tab.untitled = "Untitled " .. number, number
    end
    return append(self, tab)
end

function Tabs:create()
    if #self.items == Tabs.limit then return nil, "8 tabs open. Close a tab to add one." end
    return self:add_document(Document.new(nil, self.history))
end

function Tabs:open(path)
    local resolved, err = Files.resolve(path)
    if not resolved then return nil, err end
    local index = self:find(Files.key(resolved))
    if index then
        self.active = index
        return true
    end
    if #self.items == Tabs.limit then return nil, "8 tabs open. Close a tab to open this file." end
    collectgarbage("collect")
    local document
    document, err = Files.read(resolved, self.history)
    if not document then return nil, err end
    return self:add_document(document, resolved)
end

function Tabs:reload()
    local tab = self:current()
    local document, err = Files.read(tab.path, self.history)
    if not document then return nil, err end
    self.history:detach(tab.document)
    tab.document = document
    return true
end

function Tabs:close_current()
    if self.active == 0 then return end
    local tab = table.remove(self.items, self.active)
    self.history:detach(tab.document)
    self.active = math.min(self.active, #self.items)
end

return Tabs
