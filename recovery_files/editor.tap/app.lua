local path = ...
local Files = require("files")
local View = require("view")
local session, doc
local state = {path = path, top = 1, left = 0, blink = 0, mode = "edit", query = ""}
local elapsed = 0
local held_for, next_repeat = {}, {}

local function message(text)
    state.message, state.message_age = text, 0
end

local function change_mode(mode)
    doc:end_group()
    state.mode = mode
    held_for, next_repeat = {}, {}
    input.reset()
end

function init()
    local err
    session, err = Files.new(io, fs):open(path)
    if not session then error(path .. ": " .. tostring(err), 0) end
    doc = session.document
    View.draw(doc, state)
end

local function find(direction, inclusive)
    state.match = doc:find(state.query, direction, inclusive)
    if state.query ~= "" and not state.match then message("No matches") else state.message = nil end
end

local function find_input(text, controls)
    local seen = {}
    for char in text:gmatch(".") do
        seen[char] = true
        if char == "\n" or char == "\r" then find(input.key(4, 2) and -1 or 1)
        elseif char == "\b" then state.query = state.query:sub(1, -2); find(1, true)
        elseif (char == "\t" or char:match("[ -~]")) and #state.query < 256 then
            state.query = state.query .. char
            find(1, true)
        end
    end
    if not controls then return end
    if input.keyp(4, 14) and not seen["\n"] and not seen["\r"] then find(input.key(4, 2) and -1 or 1) end
    if input.keyp(3, 14) and not seen["\b"] then state.query = state.query:sub(1, -2); find(1, true) end
    if input.keyp(3, 1) and not seen["\t"] and #state.query < 256 then
        state.query = state.query .. "\t"; find(1, true)
    end
end

local function repeat_key(row, col, dt)
    local id = row .. ":" .. col
    if not input.key(row, col) then held_for[id], next_repeat[id] = nil, nil; return false end
    held_for[id] = (held_for[id] or 0) + dt
    if input.keyp(row, col) then
        next_repeat[id] = 0.4
        return true
    end
    if next_repeat[id] and held_for[id] >= next_repeat[id] then
        next_repeat[id] = held_for[id] + 0.05
        return true
    end
    return false
end

local function shortcut()
    doc:end_group()
    if input.keyp(4, 4) then -- S
        local ok, result = session:save()
        message(result or (ok and "Saved" or "Save failed"))
    elseif input.keyp(5, 3) then doc:undo(); state.match = nil -- Z
    elseif input.keyp(3, 7) then doc:redo(); state.match = nil -- Y
    elseif input.keyp(4, 6) then -- F
        if state.mode ~= "find" then change_mode("find") end
        find(1, true)
    end
end

local function navigate(dt, control)
    for _, key in ipairs({{5, 11, "left"}, {5, 13, "right"}, {4, 12, "up"}, {5, 12, "down"}}) do
        if repeat_key(key[1], key[2], dt) then
            local direction = key[3]
            if control and (direction == "left" or direction == "right") then
                doc:move(direction == "left" and "line_start" or "line_end")
            else
                doc:move(direction, control and View.rows or 1)
            end
            state.blink = 0
        end
    end
end

local function edit(text, dt)
    state.match = nil
    -- The FIFO can contain typing and several control characters in one poll.
    -- Preserve their order, using matrix state only for controls absent from text.
    local seen = {}
    local function apply(ok, err)
        if not ok then message(err) end
    end
    local from = 1
    while from <= #text do
        local first, last = text:find("[ -~]+", from)
        if first == from then
            apply(doc:insert(text:sub(first, last), "typing", elapsed))
            from = last + 1
        else
            local char = text:sub(from, from)
            seen[char] = true
            if char == "\n" or char == "\r" then apply(doc:insert("\n"))
            elseif char == "\t" then apply(doc:tab())
            elseif char == "\b" then apply(doc:erase(true))
            else message("Unsupported input") end
            from = from + 1
        end
    end
    -- Text excludes Ctrl/Alt combinations at the native event boundary. Any
    -- buffered bytes still belong to the document even if a modifier is now held.
    if input.keyp(1, 1) then
        if doc:dirty() then change_mode("discard") else os.exit() end
        return
    end
    if input.key(5, 1) then navigate(dt, true); shortcut(); return end
    if input.key(5, 2) then doc:end_group(); return end -- Alt
    navigate(dt, false)
    if repeat_key(3, 14, dt) and not seen["\b"] then apply(doc:erase(true)) end
    if repeat_key(1, 14, dt) then apply(doc:erase(false)) end
    if input.keyp(4, 14) and not seen["\n"] and not seen["\r"] then apply(doc:insert("\n")) end
    if input.keyp(3, 1) and not seen["\t"] then apply(doc:tab()) end
end

function update(dt)
    elapsed = elapsed + dt
    state.blink = (state.blink + dt) % 1
    if state.message then
        state.message_age = state.message_age + dt
        if state.message_age > math.max(5, #state.message / 8 + 3) then state.message = nil end
    end
    local text = input.txt() -- Read once; every modal transition consumes the whole frame.
    if text ~= "" then state.blink = 0 end
    if state.mode == "discard" then
        if input.keyp(1, 1) or input.keyp(4, 14) then change_mode("edit")
        elseif text:sub(1, 1):lower() == "y" then os.exit()
        elseif text:sub(1, 1):lower() == "n" then change_mode("edit") end
    elseif state.mode == "find" then
        local control = input.key(5, 1)
        find_input(text, not control and not input.key(5, 2) and not input.keyp(1, 1))
        if input.keyp(1, 1) then change_mode("edit"); state.match = nil
        elseif control then shortcut() end
    else
        edit(text, dt)
    end
    View.draw(doc, state)
end
