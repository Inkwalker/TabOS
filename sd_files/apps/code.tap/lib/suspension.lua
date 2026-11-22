local Document = require("document")
local Files = require("files")
local History = require("history")
local Recovery = require("recovery")
local Tabs = require("tabs")
local Suspension = {}

local version = 1
local limit = Document.limit

local function integer(value, low, high)
    return math.type(value) == "integer" and value >= low and value <= high
end

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function array(value, max)
    assert(plain(value) and #value <= max, "Invalid array")
    local count = 0
    for key in pairs(value) do
        assert(integer(key, 1, #value), "Invalid array index")
        count = count + 1
    end
    assert(count == #value, "Missing array entry")
    return count
end

local function text(value, invalid)
    return type(value) == "string" and #value <= limit and not value:find(invalid)
end

local function point(value)
    assert(plain(value) and integer(value.row, 1, limit + 1)
        and integer(value.index, 1, limit + 1), "Invalid caret or selection")
    return {row = value.row, index = value.index}
end

local function position(value)
    local result = point(value)
    if value.anchor ~= nil then result.anchor = point(value.anchor) end
    assert(value.preferred == nil or integer(value.preferred, 0, 4 * limit), "Invalid preferred column")
    result.preferred = value.preferred
    return result
end

local function copy_stack(stack, totals, reverse)
    local result, previous = {}, nil
    for index = 1, array(stack, History.group_limit) do
        local edit = stack[index]
        assert(plain(edit) and integer(edit.row, 1, limit + 1) and integer(edit.index, 1, limit + 1)
            and integer(edit.last, edit.row, limit + 1) and integer(edit.stop, 1, limit + 1)
            and integer(edit.delta, -limit, limit) and integer(edit.sequence, 1, math.maxinteger - 1)
            and text(edit.removed, "[^\32-\126\t\n]") and text(edit.inserted, "[^\32-\126\t\n]"),
            "Invalid history edit")
        local sequence = edit.sequence
        assert(not totals.seen[sequence] and (not previous
            or (reverse and sequence < previous) or (not reverse and sequence > previous)), "Invalid history order")
        previous, totals.seen[sequence] = sequence, true
        totals.bytes = totals.bytes + #edit.removed + #edit.inserted
        assert(totals.bytes <= History.byte_limit, "History exceeds byte limit")
        result[index] = {row = edit.row, index = edit.index, last = edit.last, stop = edit.stop,
            delta = edit.delta, sequence = sequence, removed = edit.removed, inserted = edit.inserted,
            before = position(edit.before), after = position(edit.after)}
    end
    return result
end

local function copy_tab(value, totals)
    local result = position(value)
    assert(integer(value.top, 1, limit + 1) and integer(value.left, 0, 4 * limit)
        and math.type(value.checksum) == "integer" and integer(value.size, 0, limit)
        and (value.eol == "\n" or value.eol == "\r\n"), "Invalid document view")
    result.top, result.left = value.top, value.left
    result.checksum, result.size, result.eol = value.checksum, value.size, value.eol
    result.undo, result.redo = copy_stack(value.undo, totals, false), copy_stack(value.redo, totals, true)
    assert(#result.undo + #result.redo <= History.group_limit, "Too many history groups")
    local undo, redo = result.undo[#result.undo], result.redo[#result.redo]
    assert(not undo or not redo or undo.sequence < redo.sequence, "Invalid history cursor")
    return result
end

function Suspension.capture(state, recovery)
    local snapshot = {version = version, generation = recovery.generation,
        manifest = Recovery.checksum(recovery.signature), active = state.tabs.active, views = {},
        clipboard = state.clipboard, query = state.find.query, folder = state.folder}
    local totals = {bytes = 0, seen = {}}
    for index, tab in ipairs(state.tabs.items) do
        local doc = tab.document
        snapshot.views[index] = copy_tab({row = doc.row, index = doc.index, anchor = doc.anchor,
            preferred = doc.preferred, top = doc.top, left = doc.left, eol = doc.eol, size = doc.size,
            checksum = Recovery.checksum(doc:serialize()), undo = doc.undo, redo = doc.redo}, totals)
    end
    return snapshot
end

function Suspension.decode(snapshot)
    assert(plain(snapshot) and snapshot.version == version, "Unsupported suspension snapshot")
    local count = array(snapshot.views, Tabs.limit)
    assert(integer(snapshot.generation, 0, 0x7fffffff) and math.type(snapshot.manifest) == "integer"
        and integer(snapshot.active, count == 0 and 0 or 1, count), "Invalid session reference")
    assert(snapshot.clipboard == nil or text(snapshot.clipboard, "[^\32-\126\t\n]"), "Invalid clipboard")
    assert(text(snapshot.query, "[^\32-\126\t]"), "Invalid Find query")
    local folder = snapshot.folder
    assert(type(folder) == "string" and #folder <= 4096
        and (folder == "/sd" or Files.resolve(folder) == folder), "Invalid browser folder")
    local views, totals = {}, {bytes = 0, seen = {}}
    for index = 1, count do views[index] = copy_tab(snapshot.views[index], totals) end
    return {generation = snapshot.generation, manifest = snapshot.manifest, active = snapshot.active,
        views = views, clipboard = snapshot.clipboard, query = snapshot.query, folder = folder}
end

function Suspension.restore_document(doc, view)
    if doc.size ~= view.size or Recovery.checksum(doc:serialize()) ~= view.checksum then
        return false
    end
    if doc.eol ~= view.eol then
        if doc.modified or #doc.lines ~= 1 then return false end
        -- A clean single-line file has no newline to infer the editor's mode from.
        doc.eol = view.eol
    end
    assert(doc:valid_position(view) and view.top <= #doc.lines, "Position outside the document")
    assert(doc:valid_history(view.undo, true) and doc:valid_history(view.redo, false), "History does not match the document")
    doc:set_caret(view.row, view.index)
    doc.anchor, doc.preferred = view.anchor, view.preferred
    doc.top, doc.left = view.top, view.left
    doc.history:restore(doc, view.undo, view.redo)
    return true
end

return Suspension
