local launch_path = ...
local Button = require("button")
local Checkpoint = require("checkpoint")
local ColorPicker = require("color_picker")
local FileMenu = require("file_menu")
local History = require("history")
local KeyboardManager = require("keyboard_manager")
local Label = require("label")
local PanTool = require("pan_tool")
local PenTool = require("pen_tool")
local PipetteTool = require("pipette_tool")
local PngFile = require("png_file")
local SpriteCanvas = require("sprite_canvas")
local ToolManager = require("tool_manager")
local ToolPanel = require("tool_panel")
local width, height = gfx.width, gfx.height
local toolbar_height, status_height = 24, 9
local status_y = height - status_height
local panel_width = 20
local picker_x = width - ColorPicker.width
local workspace_width, workspace_height = picker_x - panel_width, status_y - toolbar_height
local zoom_out_x, zoom_in_x, zoom_button_width = width - 92, width - 28, 24
local theme = assert(fs.read_table(os.path("theme.ltab")))
local palette_path = os.path("palettes/default.png")
local checkpoint_root = os.path(".recovery")
local history_tools = {[PenTool.history_id] = PenTool}
local colors = {}
for _, name in ipairs({"workspace", "panel", "button", "text", "muted", "accent", "error", "active_color"}) do
    local rgb = assert(theme[name], "Missing theme color " .. name)
    colors[name] = gfx.rgb(rgb[1], rgb[2], rgb[3])
end

local menu, zoom_out_button, zoom_in_button
local document, color_picker
local canvas = SpriteCanvas.new(panel_width, toolbar_height, workspace_width, workspace_height, colors.workspace)
local tools = ToolManager.new(canvas, function(tool, payload)
    document.history:record(tool, payload)
end)
local pen = PenTool.new(colors.active_color, colors.accent)
local pipette = PipetteTool.new(function(color)
    pen.color = color
    color_picker:set_custom_color(color)
end, colors.accent)
tools:set_active(PanTool)
local tool_panel = ToolPanel.new({x = 0, y = toolbar_height, width = panel_width, height = workspace_height},
    colors, tools, {PanTool, pen, pipette})
local title_x = 32
local title_label = Label.new(title_x, 8, zoom_out_x - title_x - 4, "Sprite Editor", colors.text)
local zoom_x = zoom_out_x + zoom_button_width
local zoom_label = Label.new(zoom_x, 8, zoom_in_x - zoom_x, "", colors.text, "center")
zoom_label.visible = false
local hint_label = Label.new(canvas.x, toolbar_height + (workspace_height - 8) // 2, workspace_width,
    "Open a PNG to get started", colors.muted, "center")
local status_label = Label.new(6, status_y + (status_height - 8) // 2, width - 10, "Ctrl+O", colors.muted)
local touch_held = false

local function update_zoom_label()
    zoom_label:set_text(canvas.zoom .. "x")
    zoom_out_button.enabled = canvas.zoom > 1
end

local function update_status(message, color)
    status_label.color = color or (message and colors.error or colors.muted)
    if message then
        status_label:set_text(message)
    elseif document then
        local image = document.image
        status_label:set_text(string.format("%d x %d px", image.width, image.height))
    else
        status_label:set_text("Ctrl+O")
    end
end

local function close_document()
    if not document then return end
    document.image:close()
    document = nil
end

local function open_image(path, view)
    view = view or {}
    local image, history, source, err
    if view.checkpoint then
        image, history = Checkpoint.read(checkpoint_root, view.checkpoint, history_tools)
        if not image then return nil, history end
        source = view.source
    else
        source = fs.stat(path)
        image, err = gfx.load_sprite(path)
        if not image then return nil, err end
        history = History.new(history_tools)
    end

    local ready
    ready, err = canvas:set_sprite(image, view.zoom, view.pan_x, view.pan_y)
    if not ready then
        image:close()
        return nil, err
    end

    -- Older suspended sessions carry unsaved pixels in their state table.
    if view.edits and not view.checkpoint then
        for y, row in pairs(view.edits) do
            for x, color in pairs(row) do canvas:paint_pixel(x, y, color) end
        end
        if canvas:flush_edits() then history:mark_dirty() end
    end

    close_document()
    document = {path = path, source = source, image = image, history = history}
    pen:reset(canvas, view.cursor_x, view.cursor_y)
    pipette.cursor:reset(canvas, view.pipette_x, view.pipette_y)
    title_label:set_text(path:match("[^/]+$") or "Sprite Editor")
    hint_label.visible = false
    zoom_label.visible = true
    update_zoom_label()
    return true
end

local function draw()
    canvas:draw()
    if document then tools:draw() end
    hint_label:draw()
    tool_panel:draw()
    color_picker:draw()

    gfx.rectfill(0, 0, width, toolbar_height, colors.panel)
    title_label:draw()
    if document then
        zoom_out_button:draw()
        zoom_in_button:draw()
    end
    zoom_label:draw()

    gfx.rectfill(0, status_y, width, status_height, colors.panel)
    status_label:draw()

    menu:draw()
end

local function request_file(options, on_selected)
    tools:cancel_drag()
    if not os.file_dialog then
        update_status("File picker unavailable")
        draw()
        return
    end
    options.directory = document and document.path:match("^(.+)/[^/]+$") or "/sd"
    local queued, err = os.file_dialog(options, function(path, detail)
        if path then
            on_selected(path)
        elseif detail then
            update_status(detail)
        end
        draw()
    end)
    if not queued then update_status(err) end
    draw()
end

local function request_open()
    request_file({mode = "open"}, function(path)
        local _, detail = open_image(path)
        update_status(detail)
    end)
end

local function save_image(path, source, create)
    canvas:flush_edits()
    local ok, message = PngFile.save(document.image, path, source, create)
    if not ok then
        update_status(message or "Save failed")
        return
    end

    document.path = path
    document.source = fs.stat(path)
    document.history:mark_saved()
    title_label:set_text(path:match("[^/]+$") or "Sprite Editor")
    update_status(message or "Saved", colors.accent)
end

local function request_save()
    if not document then return end
    tools:cancel_drag()
    if not document.history:is_dirty() then
        update_status("No changes to save", colors.muted)
    else
        save_image(document.path, document.source)
    end
    draw()
end

local function request_save_as()
    if not document then return end
    local name = document.path:match("[^/]+$")
    request_file({mode = "save", root = "/sd", name = name}, function(path)
        if fs.fat_name_key(path) == fs.fat_name_key(document.path) then
            save_image(path, document.source)
            return
        end

        local source, err, code = fs.stat(path)
        if source and source.type == "file" then
            menu:confirm_replace(path:match("[^/]+$"), function()
                save_image(path, source)
            end)
        elseif source then
            update_status("Save target is not a file")
        elseif code == 2 then
            save_image(path, nil, true)
        else
            update_status(err or "Cannot check save destination")
        end
    end)
end

local function step_history(undo)
    if not document then return end
    tools:cancel_drag()
    if document.history:step(canvas, undo) then
        update_status()
        draw()
    end
end

local function change_zoom(step)
    if document and canvas:zoom_by(step) then
        local cursor = tools.active.cursor
        if cursor then canvas:reveal_pixel(cursor.x, cursor.y) end
        update_zoom_label()
        draw()
    end
end

local function tool_key(key)
    if key == "`" then tools:cancel_drag() end
    if document and tools:key_pressed(key) then draw() end
end

local function request_close()
    tools:cancel_drag()
    os.exit()
end

local button_colors = {background = colors.button, text = colors.accent, disabled_text = colors.muted}
menu = FileMenu.new(toolbar_height, colors,
    {open = request_open, save = request_save, save_as = request_save_as, exit = request_close}, draw)
zoom_out_button = Button.new(zoom_out_x, 3, zoom_button_width, 18, "-", button_colors, function() change_zoom(-1) end)
zoom_in_button = Button.new(zoom_in_x, 3, zoom_button_width, 18, "+", button_colors, function() change_zoom(1) end)
local keyboard = KeyboardManager.new({close = request_close, open = request_open, save = request_save,
    undo = function() step_history(true) end, redo = function() step_history(false) end,
    zoom = change_zoom, tool_key = tool_key})

function init(saved, explicit_args)
    color_picker = ColorPicker.new(picker_x, toolbar_height, workspace_height, colors.panel, pen.color, palette_path)
    pen.color = color_picker:restore(saved and saved.picker)
    local path = explicit_args and os.path(launch_path) or saved and saved.path
    local message
    local view
    if path and saved and saved.path and fs.fat_name_key(path) == fs.fat_name_key(saved.path) then
        view = saved
    end
    if path then
        local opened
        opened, message = open_image(path, view)
        if not opened and not view and saved and saved.path then
            view = saved
            local detail
            opened, detail = open_image(saved.path, saved)
            if not opened and saved.checkpoint then message = detail end
        end
        if not opened and view and view.checkpoint then
            error("Cannot resume Sprite Editor: " .. (message or "checkpoint load failed"), 0)
        end
    end
    if document and view then
        if view.tool == "pen" then tools:set_active(pen) end
        if view.tool == "pipette" then tools:set_active(pipette) end
    end
    update_status(message)
    draw()
    Checkpoint.clear(checkpoint_root)
end

function update()
    local contacts = input.touch()
    local touch = contacts[1]
    local press = not touch_held and touch or nil
    touch_held = touch ~= nil
    if menu:update_popup(press) then return end
    if keyboard:update() then press = nil end
    if menu:press(press, document ~= nil) then
        tools:cancel_drag()
        draw()
        return
    end

    local color = color_picker:update_touch(touch, press)
    if color then
        pen.color = color
        draw()
        return
    end
    if tool_panel:press(press) then
        draw()
        return
    end
    if not document then return end
    if zoom_out_button:press(press) or zoom_in_button:press(press) then return end
    if tools:update_touch(contacts, press) then draw() end
end

function save_state()
    local picker = color_picker:save_state()
    if not document then return picker and {picker = picker} end
    tools:cancel_drag()
    canvas:flush_edits()
    local checkpoint
    if document.history:needs_checkpoint() then
        local err
        checkpoint, err = Checkpoint.write(checkpoint_root, document.image, document.history)
        if not checkpoint then
            local message = "Cannot suspend Sprite Editor: " .. err
            update_status(message)
            draw()
            return nil, message
        end
    end
    local tool = tools.active == pen and "pen" or "pan"
    if tools.active == pipette then tool = "pipette" end
    return {path = document.path, zoom = canvas.zoom, pan_x = canvas.pan_x, pan_y = canvas.pan_y,
        checkpoint = checkpoint, source = checkpoint and document.source, picker = picker,
        cursor_x = pen.cursor.x, cursor_y = pen.cursor.y,
        pipette_x = pipette.cursor.x, pipette_y = pipette.cursor.y, tool = tool}
end

function deinit()
    tools:cancel_drag()
    menu:close()
    tool_panel:close()
    if color_picker then color_picker:close() end
    canvas:close()
    close_document()
end
