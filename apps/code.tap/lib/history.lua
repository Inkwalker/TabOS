local History = {group_limit = 128, byte_limit = 512 * 1024}
History.__index = History
local typing_timeout = 0.75

function History.new()
    return setmetatable({documents = {}, bytes = 0, sequence = 0}, History)
end

local function cost(edit)
    return #edit.removed + #edit.inserted
end

local function clear(history, stack)
    for i = #stack, 1, -1 do
        history.bytes = history.bytes - cost(stack[i])
        stack[i] = nil
    end
end

function History:attach(doc)
    self.documents[doc] = true
end

function History:detach(doc)
    clear(self, doc.undo)
    clear(self, doc.redo)
    self.documents[doc] = nil
end

local function remove_oldest(history, stack)
    history.bytes = history.bytes - cost(table.remove(stack, 1))
end

function History:trim()
    while self.bytes > self.byte_limit do
        local oldest, stack, redo
        for doc in pairs(self.documents) do
            for _, candidate in ipairs({doc.undo, doc.redo}) do
                local is_redo = candidate == doc.redo
                local edit = candidate[is_redo and #candidate or 1]
                if edit and (not oldest or edit.sequence < oldest) then
                    oldest, stack, redo = edit.sequence, candidate, is_redo
                end
            end
        end
        if redo then
            -- Later redo records depend on the next edit being reapplied first.
            clear(self, stack)
        else
            remove_oldest(self, stack)
        end
    end
end

function History:record(doc, edit, typing, time)
    clear(self, doc.redo)
    local previous = doc.undo[#doc.undo]
    if typing and previous and doc.typing and previous.row == edit.row
        and previous.index + #previous.inserted == edit.index
        and (not time or not previous.time or time - previous.time <= typing_timeout) then
        previous.inserted = previous.inserted .. edit.inserted
        previous.after, previous.time = edit.after, time
        previous.delta = previous.delta + edit.delta
        self.bytes = self.bytes + #edit.inserted
    else
        self.sequence = self.sequence + 1
        edit.sequence, edit.time = self.sequence, time
        doc.undo[#doc.undo + 1] = edit
        self.bytes = self.bytes + cost(edit)
        if #doc.undo > self.group_limit then remove_oldest(self, doc.undo) end
    end
    doc.typing = typing
    self:trim()
end

return History
