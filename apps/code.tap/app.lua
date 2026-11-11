local path = ...
local Tabs = require("tabs")
local View = require("view")
local Keyboard = require("keyboard")
local Browser = require("browser")
local Files = require("files")
local Find = require("find")
local Document = require("document")
local Recovery = require("recovery")
local Suspension = require("suspension")

local state = {tabs = Tabs.new(), find = Find.new(), mode = "edit", first_tab = 1, blink = 0, folder = "/sd"}
local keyboard = Keyboard.new()
local recovery = Recovery.new()
local touch_id, touch_target, gesture
local long_press_time, drag_threshold = 0.5, 3
local directions = {"left", "right", "up", "down"}
local shortcuts = {{"f", "find"}, {"a", "select_all"}, {"x", "cut"}, {"c", "copy"}, {"v", "paste"},
    {"z", "undo"}, {"y", "redo"}}
local edit_commands = {select_all = true, cut = true, copy = true, paste = true, undo = true, redo = true}

local function change_mode(mode)
    state.mode = mode
    touch_target, gesture = nil, nil
    local tab = state.tabs:current()
    if tab then tab.document:break_group() end
    keyboard:reset_repeat()
end

local function reveal_tab()
    local active = state.tabs.active
    local max_first = math.max(1, #state.tabs.items - View.visible_tabs + 1)
    state.first_tab = math.max(1, math.min(state.first_tab, active, max_first))
    state.first_tab = math.max(state.first_tab, active - View.visible_tabs + 1)
    state.blink = 0
    touch_target, gesture = nil, nil
    local tab = state.tabs:current()
    if tab then tab.document:break_group() end
    keyboard:reset_repeat()
end

local function report(err)
    state.message = err
    state.message_time = err and 5 or nil
end

local function recovery_result(ok, detail)
    local previous = state.recovery_error
    state.recovery_error = not ok and (detail or "SD write failed") or nil
    return previous ~= state.recovery_error
end

local function flush_recovery(drafts, discarded)
    local ok, detail = recovery:flush(state.tabs, keyboard.time, drafts, discarded)
    recovery.retry_at = ok and 0 or keyboard.time + 2
    recovery_result(ok, detail)
    return ok
end

local function create_tab()
    local _, err = state.tabs:create()
    report(err)
    reveal_tab()
end

local function close_tab()
    local tab = state.tabs:current()
    if not tab then return end
    recovery:retire(tab)
    state.tabs:close_current()
    flush_recovery()
    reveal_tab()
end

local function dialog(title, detail, buttons, back)
    state.dialog = {title = title, detail = detail, buttons = buttons, row = #buttons, page = 1, back = back}
    change_mode("dialog")
end

local function return_to_editor()
    state.pending, state.discarded = nil, nil
    state.browser, state.overwrite, state.dialog = nil, nil, nil
    change_mode("edit")
end

local function failure(title, detail, back)
    state.pending, state.discarded = nil, nil
    back = back or "back"
    dialog(title, detail, {{"OK", back}}, back)
end

local function confirm_close()
    local tab = state.tabs:current()
    dialog(state.pending == "exit" and "Unsaved changes before exit" or "Close modified tab?",
        tab.path or tab.name,
        {{"Save (S)", "save", "s"}, {"Discard (Y)", "discard", "y"}, {"Cancel", "back", "n"}}, "back")
end

local function finish_exit()
    for tab in pairs(state.discarded) do recovery:retire(tab) end
    if flush_recovery("all", state.discarded) then
        state.exiting = true
        os.exit()
    else
        dialog("Recovery update failed", state.recovery_error,
            {{"Retry", "retry_exit"}, {"Exit anyway", "exit_anyway"}}, "wait")
        state.dialog.row = 1
    end
end

local function advance_exit()
    for index, tab in ipairs(state.tabs.items) do
        if tab.document.modified and not state.discarded[tab] then
            state.tabs:activate(index)
            reveal_tab()
            confirm_close()
            return
        end
    end
    finish_exit()
end

local function finish_close()
    if state.pending == "exit" then
        advance_exit()
    else
        local closing = state.pending == "close"
        return_to_editor()
        if closing then close_tab() end
    end
end

local function open_browser(saving)
    if saving and not state.tabs:current() then return end
    state.browser = Browser.new(state.folder, saving)
    state.overwrite = nil
    report(nil)
    change_mode("browser")
end

local function save_to(path, expected, save_as)
    local tab = state.tabs:current()
    local doc = tab.document
    local bytes = doc:serialize()
    local ok, detail, changed = Files.save(path, expected, bytes)
    if not ok then
        if changed and not save_as then
            dialog("Source changed on SD", detail,
                {{"Reload", "reload"}, {"Save As", "save_as"}, {"Cancel", "back"}}, "back")
        else
            failure("Save failed", detail, save_as and "browser_back")
        end
        return
    end
    doc:mark_saved(bytes)
    state.tabs:set_path(tab, path)
    recovery:retire(tab)
    flush_recovery()
    state.folder = Files.parent(path)
    state.browser, state.overwrite = nil, nil
    if detail then
        dialog("Saved with a warning", detail, {{"OK", "saved"}}, "saved")
    else
        report("Saved")
        finish_close()
    end
end

local function choose_save_target()
    local browser = state.browser
    if browser.error then return end
    local path, err = Files.target(browser.folder, browser.name)
    if not path then failure("Save As", err, "browser_back"); return end
    local index = state.tabs:find(Files.key(path))
    if index and index ~= state.tabs.active then
        state.open_target = index
        dialog("File already open in another tab", path,
            {{"Activate tab", "activate_target"}, {"Back", "browser_back"}}, "browser_back")
        return
    end
    local expected
    expected, err = Files.snapshot(path)
    if err then failure("Cannot use this target", err, "browser_back"); return end
    if expected then
        path, err = Files.named_child(browser.folder, browser.name)
        if not path then failure("Cannot use this target", err, "browser_back"); return end
        state.overwrite = {path = path, expected = expected}
        dialog("Replace existing file?", path,
            {{"Replace", "overwrite"}, {"Back", "browser_back"}}, "browser_back")
    else
        save_to(path, nil, true)
    end
end

local function open_entry()
    local browser = state.browser
    local entry = browser.entries[browser.row]
    if not entry then return end
    if entry.directory then
        browser:load(entry.path)
        change_mode("browser")
    elseif browser.saving then
        browser:set_name(entry.name)
    else
        local ok, err = state.tabs:open(entry.path)
        if not ok then failure("Open failed", err, "browser_back"); return end
        state.folder = browser.folder
        return_to_editor()
        reveal_tab()
    end
end

local function reload()
    local tab = state.tabs:current()
    local ok, err = state.tabs:reload()
    if not ok then failure("Reload failed", err); return end
    recovery:retire(tab)
    flush_recovery()
    return_to_editor()
    reveal_tab()
    report("Reloaded")
end

local function restore_tab(entry, doc, source_path, draft)
    local tabs = state.tabs
    tabs:add_document(doc, source_path, entry.number > 0 and entry.number or nil)
    recovery:attach(tabs:current(), entry, draft)
end

local function finish_launch(launch, requested)
    local tabs = state.tabs
    state.launch = nil
    return_to_editor()
    tabs:activate(launch.active or 1)
    if launch.folder then state.folder = launch.folder end
    if requested then
        local resolved = Files.resolve(requested)
        local index = resolved and tabs:find(Files.key(resolved))
        local err
        if index then
            tabs:activate(index)
        else
            resolved, err = Files.startup_path(requested)
            if resolved then
                local _
                _, err = tabs:open(resolved)
            end
        end
        if err then
            if #launch.issues > 0 then launch.issues[#launch.issues + 1] = err else state.message = err end
        else
            state.folder = Files.parent(tabs:current().path)
        end
    end
    local tab = tabs:current()
    if not launch.folder and tab and tab.path then state.folder = Files.parent(tab.path) end
    reveal_tab()
    if #launch.issues > 0 then
        dialog("Session restore", table.concat(launch.issues, "\n"), {{"OK", "back"}}, "back")
    end
end

local function advance_recovery(accept)
    local launch, tabs = state.launch, state.tabs
    local prompt = launch.prompt
    if prompt then
        local entry = prompt.entry
        if accept then
            if prompt.source then tabs.history:detach(prompt.source) end
            restore_tab(entry, prompt.draft, prompt.source and entry.path, prompt.reference)
        else
            tabs.history:detach(prompt.draft)
            recovery_result(recovery:discard_entry(entry))
            if prompt.source then restore_tab(entry, prompt.source, entry.path) end
        end
        launch.prompt = nil
    end

    local items = launch.session.items
    while launch.row < #items do
        launch.row = launch.row + 1
        local entry = items[launch.row]
        local source, source_error
        if entry.path then source, source_error = Files.read(entry.path, tabs.history) end
        if entry.draft > 0 then
            local draft, bytes, reference, older = recovery:draft(entry, tabs.history)
            local name = entry.path or ("Untitled " .. entry.number)
            if not draft then
                launch.issues[#launch.issues + 1] = name .. "\n" .. bytes
            elseif source and source.saved == bytes then
                tabs.history:detach(draft)
            else
                local detail = name
                if source_error then
                    detail = detail .. "\n" .. source_error .. "\nRecover as an untitled tab."
                elseif source and source.saved ~= draft.saved then
                    detail = detail .. "\nSource changed on SD. Save will check for changes."
                end
                if older then detail = detail .. "\nUsing an older complete draft." end
                launch.prompt = {entry = entry, source = source, draft = draft, reference = reference}
                dialog("Recover unsaved changes?", detail,
                    {{"Recover", "recover", "r"}, {"Discard draft", "discard_draft", "d"}}, "wait")
                state.dialog.row = 1
                return
            end
        end
        if source then
            restore_tab(entry, source, entry.path)
        elseif source_error then
            launch.issues[#launch.issues + 1] = entry.path .. "\n" .. source_error
            recovery:drop(entry)
        elseif entry.draft == 0 then
            restore_tab(entry, Document.new(nil, tabs.history))
        else
            recovery:drop(entry)
        end
    end
    finish_launch(launch, path)
end

local function resume(saved, explicit_args)
    local snapshot = Suspension.decode(saved)
    local session, err = recovery:load()
    assert(not recovery.unread, err or "SD session unavailable")
    local entries = session and session.items or {}
    assert(snapshot.generation == recovery.generation and snapshot.manifest == Recovery.checksum(recovery.signature)
        and #snapshot.views == #entries, "SD session changed or is missing")

    local tabs = state.tabs
    local launch = {issues = {}, folder = snapshot.folder}
    for index, entry in ipairs(entries) do
        local doc, detail, reference
        if entry.draft > 0 then
            doc, detail, reference = recovery:draft(entry, tabs.history, true)
            assert(doc, detail)
        elseif entry.path then
            doc, detail = Files.read(entry.path, tabs.history)
        else
            doc = Document.new(nil, tabs.history)
        end
        if doc then
            local view = snapshot.views[index]
            if not Suspension.restore_document(doc, view) then
                assert(not reference and entry.path, "Suspended draft contents changed")
                View.restore_position(doc, view)
                launch.issues[#launch.issues + 1] = entry.path .. "\nSource changed while suspended."
            end
            restore_tab(entry, doc, entry.path, reference)
            if index <= snapshot.active or not launch.active then launch.active = tabs.active end
        else
            launch.issues[#launch.issues + 1] = entry.path .. "\n" .. detail
        end
    end
    state.clipboard = snapshot.clipboard
    state.find.query, state.find.caret = snapshot.query, #snapshot.query + 1
    finish_launch(launch, explicit_args ~= false and path or nil)
end

local function set_tab_row(index)
    if state.tabs.items[index] then
        state.tab_row, state.path_page = index, 1
    end
end

local function page_path(step)
    local tab = state.tabs.items[state.tab_row]
    if tab then state.path_page = math.max(1, math.min(View.path_pages(tab), state.path_page + step)) end
end

local function edit_command(doc, action)
    local changed, message
    if action == "select_all" then
        doc:select_all()
        changed = true
    elseif action == "copy" or action == "cut" then
        local text = doc:copy()
        if text then
            state.clipboard = text
            if action == "cut" then changed = doc:paste("") end
            message = action == "cut" and "Cut" or "Copied"
        end
    elseif action == "paste" then
        if state.clipboard then changed, message = doc:paste(state.clipboard) end
    else
        changed = doc:step_history(action == "undo")
    end
    if changed then
        View.reveal_caret(doc)
        state.blink = 0
    end
    report(message)
end

local function find_match(backwards)
    local doc = state.tabs:current().document
    local found, message = state.find:select(doc, backwards)
    if found then
        doc.left = math.min(doc.left, doc:column_at(doc.row, doc.anchor.index))
        View.reveal_caret(doc, View.find_rows)
        state.blink = 0
    end
    report(message)
end

local function perform(action)
    local tabs = state.tabs
    local current = tabs:current()
    if action == "menu" then
        state.menu_row = 1
        change_mode("menu")
    elseif action == "back" then
        return_to_editor()
    elseif action == "recover" or action == "discard_draft" then
        advance_recovery(action == "recover")
    elseif action == "retry_exit" then
        finish_exit()
    elseif action == "exit_anyway" then
        state.exiting = true
        os.exit()
    elseif action == "home" then
        change_mode("edit")
        if os.suspend then
            state.going_home = true
            os.suspend()
        else
            report("Update TabOS to use Home")
        end
    elseif action == "find" then
        if current then
            report(nil)
            change_mode("find")
        end
    elseif action == "find_next" or action == "find_previous" then
        find_match(action == "find_previous")
    elseif action == "open" or action == "save_as" then
        open_browser(action == "save_as")
    elseif action == "save" and current then
        if current.path then save_to(current.path, current.document.saved, false)
        else open_browser(true) end
    elseif action == "saved" then
        report("Saved")
        finish_close()
    elseif action == "choose_target" then
        choose_save_target()
    elseif action == "overwrite" then
        local target = state.overwrite
        save_to(target.path, target.expected, true)
    elseif action == "browser_back" then
        state.dialog, state.overwrite = nil, nil
        change_mode("browser")
    elseif action == "browser_parent" then
        state.browser:load(Files.parent(state.browser.folder))
        change_mode("browser")
    elseif action == "browser_retry" then
        state.browser:load(state.browser.folder)
        change_mode("browser")
    elseif action == "browser_name" then
        state.browser.focus = "name"
    elseif action == "browser_up" or action == "browser_down" then
        local browser = state.browser
        browser:scroll(browser.top + (action == "browser_up" and -Browser.rows or Browser.rows))
    elseif action == "activate_target" then
        tabs:activate(state.open_target)
        return_to_editor()
        reveal_tab()
    elseif action == "reload" then
        if current.document.modified then
            dialog("Discard local edits and reload?", current.path,
                {{"Reload", "reload_confirmed"}, {"Cancel", "back"}}, "back")
        else
            reload()
        end
    elseif action == "reload_confirmed" then
        reload()
    elseif action == "new" then
        change_mode("edit")
        create_tab()
    elseif edit_commands[action] then
        change_mode("edit")
        if current then edit_command(current.document, action) end
    elseif action == "tabs" then
        state.tab_row, state.path_page = tabs.active, 1
        change_mode("tabs")
    elseif action == "strip_previous" then
        state.first_tab = state.first_tab - 1
    elseif action == "strip_next" then
        state.first_tab = state.first_tab + 1
    elseif action == "path_previous" then
        page_path(-1)
    elseif action == "path_next" then
        page_path(1)
    elseif action == "dialog_previous" or action == "dialog_next" then
        local prompt = state.dialog
        local step = action == "dialog_previous" and -1 or 1
        prompt.page = math.max(1, math.min(View.dialog_pages(prompt), prompt.page + step))
    elseif action == "activate" or type(action) == "number" then
        if state.mode == "browser" then
            state.browser:select(action)
            open_entry()
        elseif state.mode == "tabs" and action ~= "activate" then
            set_tab_row(action)
        else
            tabs:activate(action == "activate" and state.tab_row or action)
            change_mode("edit")
            report(nil)
            reveal_tab()
        end
    elseif action == "discard" then
        if state.pending == "exit" then state.discarded[current] = true end
        finish_close()
    elseif action == "close" then
        if current and current.document.modified then
            state.pending = "close"
            confirm_close()
        else
            return_to_editor()
            close_tab()
        end
    elseif action == "exit" then
        state.pending, state.discarded = "exit", {}
        advance_exit()
    end
end

local function touch_action()
    local touches = input.touch()
    if #touches == 0 then
        local action, pending = touch_target, gesture
        touch_id, touch_target, gesture = nil, nil, nil
        if pending and pending.browser then return action end
        if pending and pending.phase == "waiting" then
            pending.word = keyboard.time - pending.started >= long_press_time
            return "place", pending
        end
        return action
    end
    if not touch_id then
        local touch = touches[1]
        touch_id, touch_target = touch.id, View.hit(state, touch.x, touch.y)
        if touch_target == "viewport" then
            local doc = state.tabs:current().document
            gesture = {phase = "waiting", x = touch.x, y = touch.y, top = doc.top, left = doc.left,
                started = keyboard.time, last_x = touch.x, last_y = touch.y}
            touch_target = nil
        elseif state.mode == "browser" and (type(touch_target) == "number" or touch_target == "browser_list") then
            gesture = {browser = true, x = touch.x, y = touch.y, top = state.browser.top}
        end
        return
    end
    local contact
    for _, touch in ipairs(touches) do
        if touch.id == touch_id then contact = touch; break end
    end
    if not contact then
        touch_target, gesture = nil, nil
        return
    end
    if gesture and gesture.browser then
        local dy = contact.y - gesture.y
        if gesture.drag or math.max(math.abs(contact.x - gesture.x), math.abs(dy)) > drag_threshold then
            gesture.drag, touch_target = true, nil
            local top = state.browser.top
            state.browser:scroll(gesture.top - math.floor(dy / Browser.row_height + 0.5))
            if state.browser.top ~= top then return "browser_scrolled" end
        elseif View.hit(state, contact.x, contact.y) ~= touch_target then
            touch_target = nil
        end
        return
    end
    if touch_target and View.hit(state, contact.x, contact.y) ~= touch_target then touch_target = nil end
    if not gesture or gesture.phase == "held" then return end

    local dx, dy = contact.x - gesture.x, contact.y - gesture.y
    gesture.last_x, gesture.last_y = contact.x, contact.y
    if gesture.phase == "waiting" then
        if math.max(math.abs(dx), math.abs(dy)) > drag_threshold then
            gesture.phase = "drag"
            gesture.vertical = math.abs(dy) >= math.abs(dx)
        elseif keyboard.time - gesture.started >= long_press_time then
            gesture.phase, gesture.word = "held", true
            return "place", gesture
        end
    end
    if gesture.phase == "drag" and (gesture.dx ~= dx or gesture.dy ~= dy) then
        gesture.dx, gesture.dy = dx, dy
        return "scroll", gesture
    end
end

local function browser_keys(text)
    local browser = state.browser
    if browser.saving and Keyboard.pressed("tab") then
        browser.focus = browser.focus == "list" and "name" or "list"
        return true
    end
    local enter = Keyboard.pressed("enter")
    if enter and browser.saving and text:find("[ -~\b]") then
        browser.focus = "name"
        browser:edit_name(text:match("^[^\r\n]*"))
    end
    if enter then
        if browser.focus == "name" then choose_save_target() else open_entry() end
        return true
    end
    if keyboard:repeat_press("up") then browser:select(browser.row - 1); return true end
    if keyboard:repeat_press("down") then browser:select(browser.row + 1); return true end
    if browser.saving and (browser.focus == "name" or text:find("[ -~\b]")) then
        local name, caret, focus = browser.name, browser.caret, browser.focus
        browser.focus = "name"
        if keyboard:repeat_press("left") then browser:move_caret(-1) end
        if keyboard:repeat_press("right") then browser:move_caret(1) end
        if keyboard:repeat_press("backspace") and not Keyboard.pressed("backspace")
            and not text:find("\b", 1, true) then
            text = text .. "\b"
        end
        if keyboard:repeat_press("delete") then text = text .. "\127" end
        browser:edit_name(text)
        return browser.name ~= name or browser.caret ~= caret or focus ~= "name"
    end
    if Keyboard.pressed("left") and browser.folder ~= "/sd" then
        perform("browser_parent")
        return true
    end
    return false
end

local function dialog_keys(text)
    local prompt = state.dialog
    if Keyboard.pressed("enter") then
        perform(prompt.buttons[prompt.row][2])
        return true
    end
    for _, button in ipairs(prompt.buttons) do
        if text:lower() == button[3] then perform(button[2]); return true end
    end
    if Keyboard.pressed("left") then prompt.row = math.max(1, prompt.row - 1); return true end
    if Keyboard.pressed("right") then prompt.row = math.min(#prompt.buttons, prompt.row + 1); return true end
    if Keyboard.pressed("up") then perform("dialog_previous"); return true end
    if Keyboard.pressed("down") then perform("dialog_next"); return true end
    return false
end

local function find_keys(text)
    local find = state.find
    local query, caret = find.query, find.caret
    if keyboard:repeat_press("left") then find:move(-1) end
    if keyboard:repeat_press("right") then find:move(1) end
    if keyboard:repeat_press("backspace") and not Keyboard.pressed("backspace")
        and not text:find("\b", 1, true) then
        text = text .. "\b"
    end
    if keyboard:repeat_press("delete") then text = text .. "\127" end

    local backwards = Keyboard.down("shift")
    local offset, searched = 1, false
    while offset <= #text do
        local enter = text:find("[\r\n]", offset)
        local previous = find.query
        find:edit(text:sub(offset, enter and enter - 1))
        if find.query ~= previous then report(nil) end
        if not enter then break end
        find_match(backwards)
        searched = true
        offset = enter + (text:sub(enter, enter + 1) == "\r\n" and 2 or 1)
    end
    if not searched and Keyboard.pressed("enter") then
        find_match(backwards)
        searched = true
    end
    return searched or find.query ~= query or find.caret ~= caret
end

local function modal_keys(text)
    if Keyboard.down("ctrl") or Keyboard.down("alt") then return false end
    local mode = state.mode
    if mode == "menu" then
        if Keyboard.pressed("enter") then perform(View.menu_action(state.menu_row)); return true end
        local step = Keyboard.pressed("up") and -1 or (Keyboard.pressed("down") and 1 or 0)
        if step ~= 0 then
            state.menu_row = (state.menu_row - 1 + step) % View.menu_rows + 1
            return true
        end
    elseif mode == "tabs" then
        if Keyboard.pressed("up") then set_tab_row(state.tab_row - 1); return true end
        if Keyboard.pressed("down") then set_tab_row(state.tab_row + 1); return true end
        if Keyboard.pressed("left") then perform("path_previous"); return true end
        if Keyboard.pressed("right") then perform("path_next"); return true end
        if Keyboard.pressed("enter") and state.tab_row > 0 then perform("activate"); return true end
    elseif mode == "browser" then
        return browser_keys(text)
    elseif mode == "dialog" then
        return dialog_keys(text)
    elseif mode == "find" then
        return find_keys(text)
    end
    return false
end

local function editor_keys(text)
    local ctrl, alt = Keyboard.down("ctrl"), Keyboard.down("alt")
    if ctrl and Keyboard.pressed("tab") then
        state.tabs:cycle(alt and -1 or 1)
        report(nil)
        reveal_tab()
        return true
    end
    if ctrl and not alt and Keyboard.pressed("n") then
        create_tab()
        return true
    end
    if ctrl and not alt and Keyboard.pressed("w") then
        perform("close")
        return true
    end
    if ctrl and not alt and Keyboard.pressed("o") then
        perform("open")
        return true
    end
    if ctrl and Keyboard.pressed("s") then
        perform(alt and "save_as" or "save")
        return true
    end

    local tab = state.tabs:current()
    if not tab then return false end
    local doc = tab.document
    local redraw = false
    if ctrl and not alt then
        for _, shortcut in ipairs(shortcuts) do
            if Keyboard.pressed(shortcut[1]) then
                perform(shortcut[2])
                return true
            end
        end
    end
    if not ctrl and not alt then
        -- Enter, Tab and Backspace already arrive in FIFO order. Only add
        -- repeats for Backspace and matrix events for the unbuffered Delete.
        if keyboard:repeat_press("backspace") and not Keyboard.pressed("backspace")
            and not text:find("\b", 1, true) then
            text = text .. "\b"
        end
        if keyboard:repeat_press("delete") then text = text .. "\127" end
        if text ~= "" then
            local _, err = doc:edit(text, keyboard.time)
            report(err)
            if not err then View.reveal_caret(doc) end
            redraw = true
        end
    end
    if not alt then
        for _, direction in ipairs(directions) do
            if keyboard:repeat_press(direction) then
                local move = direction
                if ctrl and direction == "left" then move = "line_start"
                elseif ctrl and direction == "right" then move = "line_end" end
                doc:move(move, ctrl and View.rows or 1, Keyboard.down("shift"))
                View.reveal_caret(doc)
                redraw = true
            end
        end
    end
    if redraw then
        state.blink = 0
        gesture = nil
    end
    return redraw
end

function save_state()
    if state.launch or (state.dialog and state.dialog.back == "wait") then
        return nil, "Finish the current recovery decision before suspending"
    end
    local ok, detail = recovery:checkpoint(state.tabs, keyboard.time)
    if not ok then
        recovery_result(false, detail)
        View.draw(state)
        return nil, "Cannot suspend Code: " .. (detail or "SD recovery write failed")
    end
    return Suspension.capture(state, recovery)
end

function init(saved, explicit_args)
    if saved ~= nil then
        local ok, detail = pcall(resume, saved, explicit_args)
        if not ok then error("Cannot resume Code: " .. tostring(detail), 0) end
        View.draw(state)
        return
    end
    local session, err = recovery:load()
    local issues = {}
    if recovery.unread then recovery_result(false, err)
    elseif err then issues[1] = err end
    if session then
        for _, entry in ipairs(session.items) do
            state.tabs.next_untitled = math.max(state.tabs.next_untitled, entry.number + 1)
        end
        state.launch = {session = session, row = 0, issues = issues}
        advance_recovery()
    else
        finish_launch({issues = issues}, path)
    end
    View.draw(state)
end

function update(dt)
    local text = input.txt()
    keyboard:advance(dt)
    local action, pending = touch_action()
    local caret_visible = state.blink < 0.5
    state.blink = (state.blink + dt) % 1
    local redraw = state.mode == "edit" and state.tabs:current() and caret_visible ~= (state.blink < 0.5)
    if state.message_time then
        state.message_time = state.message_time - dt
        if state.message_time <= 0 then report(nil); redraw = true end
    end
    if Keyboard.pressed("escape") then
        local back = state.mode == "dialog" and state.dialog.back or "back"
        perform(state.mode == "edit" and "menu" or back)
        redraw = true
    elseif action == "place" then
        local doc = state.tabs:current().document
        View.place(doc, pending.last_x, pending.last_y, pending.word)
        state.blink, redraw = 0, true
    elseif action == "scroll" then
        local doc = state.tabs:current().document
        doc:break_group()
        View.scroll(doc, pending.top, pending.left, pending.dx, pending.dy, pending.vertical)
        redraw = true
    elseif action == "browser_scrolled" then
        redraw = true
    elseif action then
        perform(action)
        redraw = true
    elseif state.mode == "edit" then
        redraw = editor_keys(text) or redraw
    else
        redraw = modal_keys(text) or redraw
    end
    if state.exiting then return end
    if state.going_home then
        state.going_home = nil
        return
    end
    -- Recovery prompts and exit retries hold decisions that are not yet published.
    if not state.launch and not (state.dialog and state.dialog.back == "wait") then
        local ok, detail = recovery:update(state.tabs, keyboard.time)
        if ok ~= nil or detail then redraw = recovery_result(ok, detail) or redraw end
    end
    if redraw then View.draw(state) end
end
