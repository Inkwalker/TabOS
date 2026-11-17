local Paths = require("paths")
local Operation = require("operation")
local View = require("view")
local requested = ...

local state = {
    folder = "/sd", entries = {}, history = {}, selected = {}, selected_count = 0,
    offset = 0, highlight = 1, clock = 0, search = "",
}
local actions = {}
local touch, touch_held

local function dismiss()
    state.dialog = nil
end

local function dialog(title, detail, options, cancel)
    state.dialog = View.dialog(title, detail, options, cancel)
    return state.dialog
end

local function notice(title, detail)
    dialog(title, detail, {{"OK", dismiss}})
end

local function limit_offset(offset)
    return math.max(0, math.min(offset, #state.entries - View.rows))
end

local function refresh()
    local entries, err = Paths.list(state.folder)
    state.entries = {}
    state.read_error = not entries and (err or "Directory unavailable") or nil
    state.selected_count = 0
    if not entries then return end
    local selected = {}
    for _, entry in ipairs(entries) do
        local path = Paths.join(state.folder, entry.name)
        local info = entry.type and entry or fs.stat(path)
        local kind = info and info.type
        local key = Paths.key(path)
        local app_entry = kind == "dir" and entry.name:sub(-4):lower() == ".tap"
            and fs.stat(Paths.join(path, "app.lua"))
        state.entries[#state.entries + 1] = {
            path = path, name = entry.name, key = key,
            type = kind, order = entry.name:lower(),
            app_bundle = app_entry and app_entry.type == "file",
        }
        if state.selected[key] then
            selected[key] = true
            state.selected_count = state.selected_count + 1
        end
    end
    table.sort(state.entries, function(a, b)
        if (a.type == "dir") ~= (b.type == "dir") then return a.type == "dir" end
        if a.order == b.order then return a.name < b.name end
        if state.descending then return a.order > b.order end
        return a.order < b.order
    end)
    state.selected = selected
    state.offset = limit_offset(state.offset)
    state.highlight = math.max(1, math.min(state.highlight, #state.entries))
end

local function navigate(folder, remember)
    if folder ~= state.folder then
        if remember then state.history[#state.history + 1] = state.folder end
        state.folder, state.offset, state.highlight = folder, 0, 1
        state.selected, state.search = {}, ""
    end
    dismiss()
    refresh()
end

local function edit(title, value, label, submit)
    local prompt
    local function accept()
        local ok, err = submit(prompt.text)
        if ok then dismiss() else prompt.lines = View.lines(err or "Action failed") end
        prompt.page = 1
    end
    prompt = dialog(title, "", {{label, accept}, {"Cancel", dismiss}})
    prompt.text, prompt.accept = value, accept
end

function actions.back()
    local folder = table.remove(state.history)
    if folder then navigate(folder, false) end
end

function actions.parent()
    navigate(Paths.parent(state.folder), true)
end

function actions.path()
    edit("Go to folder", state.folder, "Go", function(path)
        local folder, err = Paths.directory(path, state.folder)
        if not folder then return nil, err end
        navigate(folder, true)
        return true
    end)
end

function actions.refresh()
    dismiss()
    refresh()
end

local function new_folder()
    if state.folder == "/" then
        notice("New Folder", "Choose a storage location first.")
        return
    end
    edit("New Folder", "", "Create", function(name)
        if not Paths.valid_name(name) then return nil, "Invalid folder name" end
        local ok, err = fs.mkdir(Paths.join(state.folder, name))
        if ok then refresh() end
        return ok, err
    end)
end

local function choose_sort()
    local function sort(descending)
        state.descending = descending
        actions.refresh()
    end
    dialog("Sort by name", "Folders are shown first.", {
        {"A to Z", function() sort(false) end},
        {"Z to A", function() sort(true) end},
        {"Cancel", dismiss},
    })
end

local function locations()
    dialog("Locations", "", {
        {"SD", function() navigate("/sd", true) end},
        {"Recovery", function() navigate("/rec", true) end},
        {"Cancel", dismiss},
    })
end

function actions.menu()
    dialog("Folder actions", "", {
        {"Locations", locations}, {"New Folder", new_folder},
        {"Refresh", actions.refresh}, {"Sort", choose_sort},
        {"Refresh App Registry", function()
            local ok, err = os.refresh_app_registry()
            notice("App Registry", ok and "Application registry refreshed." or err)
        end},
        {"Close Files", function()
            if not state.operation then os.exit() end
        end},
        {"Cancel", dismiss},
    })
end

local function show_highlight(index)
    state.highlight = math.max(1, math.min(#state.entries, index))
    state.offset = limit_offset(math.min(state.highlight - 1,
        math.max(state.offset, state.highlight - View.rows)))
end

local function select_entry(index, value)
    local entry = state.entries[index]
    if not entry then return end
    local marked = state.selected[entry.key]
    if value and not marked then
        state.selected[entry.key] = true
        state.selected_count = state.selected_count + 1
    elseif not value and marked then
        state.selected[entry.key] = nil
        state.selected_count = state.selected_count - 1
    end
end

function actions.select(index)
    select_entry(index, not state.selected[state.entries[index].key])
    show_highlight(index)
end

function actions.open(index)
    local entry = state.entries[index]
    if not entry then return end
    show_highlight(index)
    if entry.type == "dir" and not entry.app_bundle then
        navigate(entry.path, true)
    else
        os.open(entry.path)
    end
end

local function remember_paths(mode, sources)
    if mode == "cut" then
        for _, path in ipairs(sources) do
            if Paths.protected(path) then
                notice("Cut", "Cannot move a storage root.")
                return
            end
        end
    end
    state.clipboard = {mode = mode, paths = sources}
    dismiss()
end

local function remove_moved(source)
    local clipboard = state.clipboard
    for index, path in ipairs(clipboard.paths) do
        if path == source then
            table.remove(clipboard.paths, index)
            break
        end
    end
    if #clipboard.paths == 0 then state.clipboard = nil end
end

local function start_operation(mode, sources)
    state.operation = Operation.new(mode, sources, state.folder, remove_moved)
    dismiss()
end

function actions.paste()
    if state.folder == "/" then
        notice("Paste Here", "Choose a storage location first.")
        return
    end
    local sources = {}
    for index, path in ipairs(state.clipboard.paths) do sources[index] = path end
    start_operation(state.clipboard.mode, sources)
end

local function confirm_delete(sources)
    for _, path in ipairs(sources) do
        if Paths.protected(path) then
            notice("Delete", "Cannot delete a storage root.")
            return
        end
    end
    local subject = #sources == 1 and Paths.name(sources[1]) or (#sources .. " selected items")
    dialog("Delete permanently?", subject, {
        {"Cancel", dismiss}, {"Delete", function() start_operation("delete", sources) end},
    }, dismiss)
end

local function rename(entry)
    if Paths.protected(entry.path) then
        notice("Rename", "Cannot rename a storage root.")
        return
    end
    edit("Rename", entry.name, "Rename", function(name)
        if not Paths.valid_name(name) then return nil, "Invalid name" end
        local ok, err = Operation.rename(entry.path, Paths.join(state.folder, name))
        if ok then refresh() end
        return ok, err
    end)
end

local function properties(entry)
    local info, err = fs.stat(entry.path)
    if not info then
        notice("Properties", err or "Item unavailable")
        return
    end
    local detail = entry.path .. "\n" .. (info.type == "dir" and "Folder" or "File")
        .. "\n" .. info.size .. " bytes\nModified (Unix seconds) " .. info.mtime
    notice("Properties", detail)
end

local function item_menu(index)
    local entry = state.entries[index]
    if not entry then return end
    show_highlight(index)
    local sources = {entry.path}
    local options = {
        {"Open", function() dismiss(); actions.open(index) end},
        {"Properties", function() properties(entry) end},
        {"Rename", function() rename(entry) end},
        {"Delete", function() confirm_delete(sources) end},
        {"Copy", function() remember_paths("copy", sources) end},
        {"Cut", function() remember_paths("cut", sources) end},
    }
    if entry.type == "file" then
        options[#options + 1] = {"Open With", function() dismiss(); os.open(entry.path, "with") end}
    elseif entry.app_bundle then
        options[#options + 1] = {"Browse Contents", function() navigate(entry.path, true) end}
    end
    options[#options + 1] = {"Cancel", dismiss}
    dialog("Item actions", entry.name, options)
end

function actions.selection()
    local sources = {}
    for _, entry in ipairs(state.entries) do
        if state.selected[entry.key] then sources[#sources + 1] = entry.path end
    end
    if #sources == 1 then
        for index, entry in ipairs(state.entries) do
            if entry.path == sources[1] then item_menu(index); return end
        end
    end
    dialog("Selected items", #sources .. " selected", {
        {"Copy", function() remember_paths("copy", sources) end},
        {"Cut", function() remember_paths("cut", sources) end},
        {"Delete", function() confirm_delete(sources) end},
        {"Cancel", dismiss},
    })
end

local function operation_result(job)
    state.operation = nil
    refresh()
    local detail = job.completed .. " completed\n" .. job.skipped .. " skipped\n" .. job.failed .. " failed"
    local pending = job.total - job.completed - job.skipped - job.failed
    if pending > 0 then detail = detail .. "\n" .. pending .. " unfinished" end
    local options = {}
    job.result = View.dialog(job.cancelled and "Operation cancelled" or "Operation finished",
        detail, options, dismiss)
    if #job.details > 0 then
        options[1] = {"Details", function()
            dialog("Operation details", table.concat(job.details, "\n"),
                {{"Back", function() state.dialog = job.result end}})
        end}
    end
    options[#options + 1] = {"OK", dismiss}
    state.dialog = job.result
end

local function advance_operation(answer, remaining)
    local job = state.operation
    if job:update(answer, remaining) then
        operation_result(job)
        return
    end
    local event = job.event
    local options = {}
    local function cancel() advance_operation("Cancel") end
    if event.kind == "progress" then
        local detail = job.path
        if event.copied then detail = detail .. ("\n%.0f KiB copied"):format(event.copied / 1024) end
        dialog("Working " .. job.index .. "/" .. job.total, detail, {{"Cancel", cancel}})
        -- Enter is reserved for choosing an answer to a prompt.
        state.dialog.focus = nil
    else
        local prompt
        for _, choice in ipairs(event.options) do
            options[#options + 1] = {choice, function() advance_operation(choice, prompt.remaining) end}
        end
        prompt = dialog(event.kind == "conflict" and "Paste conflict" or "File operation failed",
            event.detail, options, cancel)
        prompt.apply = event.batch
        prompt.focus = #options
    end
end

local keys = {
    escape = {1, 1}, backspace = {3, 14}, enter = {4, 14},
    shift = {4, 2}, ctrl = {5, 1}, a = {4, 3},
    up = {4, 12}, down = {5, 12}, left = {5, 11}, right = {5, 13},
}
local repeat_at = {}

local function pressed(name)
    return input.keyp(table.unpack(keys[name]))
end

local function held(name)
    return input.key(table.unpack(keys[name]))
end

local function repeat_press(name)
    if pressed(name) then
        repeat_at[name] = state.clock + 0.4
        return true
    end
    if not held(name) then
        repeat_at[name] = nil
    elseif repeat_at[name] and state.clock >= repeat_at[name] then
        repeat_at[name] = state.clock + 0.07
        return true
    end
end

local function edit_text(prompt, text)
    for char in text:gmatch(".") do
        if char == "\b" then
            local last = #prompt.text
            while last > 0 and (prompt.text:byte(last) & 0xc0) == 0x80 do last = last - 1 end
            prompt.text = prompt.text:sub(1, math.max(0, last - 1))
        elseif not char:find("%c") then
            prompt.text = prompt.text .. char
        end
    end
end

local function dialog_keys(text)
    local prompt = state.dialog
    if pressed("escape") then prompt.cancel(); return true end
    if prompt.text then
        if repeat_press("backspace") and not text:find("\b", 1, true) then text = text .. "\b" end
        edit_text(prompt, text)
        if pressed("enter") then prompt.accept(); return true end
        return #text > 0
    end
    if not prompt.focus then return false end
    if pressed("enter") then prompt.options[prompt.focus][2](); return true end
    if pressed("left") or pressed("up") then
        prompt.focus = math.max(1, prompt.focus - 1)
        return true
    elseif pressed("right") or pressed("down") then
        prompt.focus = math.min(#prompt.options, prompt.focus + 1)
        return true
    end
end

local function jump_to_name(text)
    if state.clock > (state.search_time or 0) then state.search = "" end
    state.search_time = state.clock + 1
    local function search(query)
        for step = 0, #state.entries - 1 do
            local index = (state.highlight - 1 + step) % #state.entries + 1
            if state.entries[index].order:sub(1, #query) == query then
                state.search = query
                show_highlight(index)
                return true
            end
        end
    end
    text = text:lower():gsub("%c", "")
    if text ~= "" then return search(state.search .. text) or search(text) end
end

local function list_keys(text)
    if pressed("escape") or pressed("backspace") then actions.parent(); return true end
    if pressed("enter") then actions.open(state.highlight); return true end
    local ctrl = held("ctrl")
    if ctrl and pressed("a") then
        if state.selected_count > 0 then
            state.selected, state.selected_count = {}, 0
        else
            for index in ipairs(state.entries) do select_entry(index, true) end
        end
        return true
    end
    if ctrl and pressed("left") then show_highlight(1); return true end
    if ctrl and pressed("right") then show_highlight(#state.entries); return true end
    local direction = repeat_press("up") and -1 or repeat_press("down") and 1
    if direction then
        local previous = state.highlight
        show_highlight(previous + direction * (ctrl and View.rows or 1))
        if not ctrl and held("shift") and state.highlight ~= previous then
            select_entry(state.highlight, true)
        end
        return true
    end
    return jump_to_name(text)
end

local function contains(target, contact)
    return contact.x >= target.x and contact.x < target.x + target.w
        and contact.y >= target.y and contact.y < target.y + target.h
end

local function touch_actions(contacts, dt)
    local contact = contacts[1]
    if not contact then
        local action = touch and touch.target and touch.target.action
        touch, touch_held = nil, false
        if action then action(); return true end
        return false
    end
    if not touch_held and #contacts == 1 then
        local list = not state.dialog and contact.y >= View.row_top and contact.y < 157
        touch = {id = contact.id, x = contact.x, y = contact.y, offset = state.offset,
            list = list, elapsed = 0}
        for _, target in ipairs(state.targets) do
            if contains(target, contact) then touch.target = target; break end
        end
    end
    touch_held = true
    if not touch then return false end
    if #contacts ~= 1 or contact.id ~= touch.id then touch = nil; return false end
    local distance = touch.y - contact.y
    if touch.list and (touch.scrolling or math.abs(distance) >= 6) then
        touch.scrolling, touch.target = true, nil
        local offset = limit_offset(touch.offset + math.floor(distance / View.row_height + 0.5))
        if offset == state.offset then return false end
        state.offset = offset
        return true
    end
    local target = touch.target
    if not target then return false end
    if not contains(target, contact) then touch.target = nil; return false end
    touch.elapsed = touch.elapsed + dt
    if target.row and target.x > 0 and touch.elapsed >= 0.55 then
        touch.target = nil
        item_menu(target.row)
        return true
    end
end

function init(saved, explicit_args)
    if saved then
        state.folder, state.history = saved.folder, saved.history
        state.offset, state.highlight = saved.offset, saved.highlight
        state.selected, state.clipboard = saved.selected, saved.clipboard
        state.descending = saved.descending
    end
    if requested and (explicit_args or not saved) then
        local folder, err = Paths.directory(requested, state.folder)
        if not folder then error(err, 0) end
        state.selected, state.offset, state.highlight = {}, 0, 1
        navigate(folder, true)
    else
        refresh()
    end
    View.load_icons()
    View.draw(state, actions)
end

function save_state()
    if state.operation then return nil, "Finish or cancel the file operation first" end
    return {folder = state.folder, history = state.history, offset = state.offset,
        highlight = state.highlight, selected = state.selected, clipboard = state.clipboard,
        descending = state.descending}
end

function deinit()
    View.close_icons()
    if state.operation then state.operation:cleanup() end
end

function update(dt)
    state.clock = state.clock + dt
    local text = input.txt()
    local contacts = input.touch()
    local changed = touch_actions(contacts, dt)
    if not changed and #contacts == 0 then
        if state.dialog then changed = dialog_keys(text) else changed = list_keys(text) end
    end
    local job = state.operation
    if job and (not job.event or job.event.kind == "progress") then
        advance_operation()
        changed = true
    end
    if changed then View.draw(state, actions) end
end
