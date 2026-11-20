local launch_path = ...
local Button = require("button")
local KeyboardManager = require("keyboard_manager")
local Label = require("label")
local PanTool = require("pan_tool")
local PenTool = require("pen_tool")
local PngFile = require("png_file")
local SpriteCanvas = require("sprite_canvas")
local ToolManager = require("tool_manager")
local ToolPanel = require("tool_panel")
local width, height = gfx.width, gfx.height
local toolbar_height, status_height = 24, 16
local panel_width = 20
local workspace_width, workspace_height = width - panel_width, height - toolbar_height - status_height
local zoom_out_x, zoom_in_x, zoom_button_width = width - 92, width - 28, 24
local theme = assert(fs.read_table(os.path("theme.ltab")))
local colors = {}
for _, name in ipairs({"workspace", "panel", "button", "text", "muted", "accent", "error", "active_color"}) do
    local rgb = assert(theme[name], "Missing theme color " .. name)
    colors[name] = gfx.rgb(rgb[1], rgb[2], rgb[3])
end

local open_button, save_button, zoom_out_button, zoom_in_button
local canvas = SpriteCanvas.new(0, toolbar_height, workspace_width, workspace_height, colors.workspace)
local tools = ToolManager.new(canvas)
local pen = PenTool.new(colors.active_color, colors.accent)
tools:set_active(PanTool)
local tool_panel = ToolPanel.new({x = workspace_width, y = toolbar_height, width = panel_width, height = workspace_height},
    colors, tools, {PanTool, pen})
local title_x = 104
local title_label = Label.new(title_x, 8, zoom_out_x - title_x - 4, "Sprite Editor", colors.text)
local zoom_x = zoom_out_x + zoom_button_width
local zoom_label = Label.new(zoom_x, 8, zoom_in_x - zoom_x, "", colors.text, "center")
zoom_label.visible = false
local hint_label = Label.new(0, toolbar_height + (workspace_height - 8) // 2, workspace_width,
    "Open a PNG to get started", colors.muted, "center")
local status_label = Label.new(6, height - 12, width - 10, "Ctrl+O", colors.muted)
local document
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
    local image, err = gfx.load_sprite(path)
    if not image then return nil, err end

    view = view or {}
    local ready
    ready, err = canvas:set_sprite(image, view.zoom, view.pan_x, view.pan_y, view.edits)
    if not ready then
        image:close()
        return nil, err
    end

    close_document()
    document = {path = path, image = image}
    save_button.enabled = true
    pen:reset(canvas, view.cursor_x, view.cursor_y)
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

    gfx.rectfill(0, 0, width, toolbar_height, colors.panel)
    open_button:draw()
    save_button:draw()
    title_label:draw()
    if document then
        zoom_out_button:draw()
        zoom_in_button:draw()
    end
    zoom_label:draw()

    gfx.rectfill(0, height - status_height, width, status_height, colors.panel)
    status_label:draw()
end

local function request_open()
    tools:cancel_drag()
    if not os.file_dialog then
        update_status("File picker unavailable")
        draw()
        return
    end
    local directory = document and document.path:match("^(.+)/[^/]+$") or "/sd"
    local queued, err = os.file_dialog({mode = "open", directory = directory}, function(path, detail)
        if not path and not detail then return end
        if path then
            local _
            _, detail = open_image(path)
        end
        update_status(detail)
        draw()
    end)
    if not queued then
        update_status(err)
        draw()
    end
end

local function request_save()
    if not document then return end
    if not next(canvas.edits) then
        update_status("No changes to save", colors.muted)
    else
        local ok, message = PngFile.save(document.image, document.path)
        if ok then
            canvas.edits = {}
            update_status(message or "Saved", colors.accent)
        else
            update_status(message or "Save failed")
        end
    end
    draw()
end

local function change_zoom(step)
    if document and canvas:zoom_by(step) then
        if tools.active == pen then canvas:reveal_pixel(pen.x, pen.y) end
        update_zoom_label()
        draw()
    end
end

local function tool_key(key)
    if document and tools:key_pressed(key) then draw() end
end

local function request_close()
    tools:cancel_drag()
    os.exit()
end

local button_colors = {background = colors.button, text = colors.accent, disabled_text = colors.muted}
open_button = Button.new(4, 3, 44, 18, "Open", button_colors, request_open)
save_button = Button.new(52, 3, 44, 18, "Save", button_colors, request_save)
save_button.enabled = false
zoom_out_button = Button.new(zoom_out_x, 3, zoom_button_width, 18, "-", button_colors, function() change_zoom(-1) end)
zoom_in_button = Button.new(zoom_in_x, 3, zoom_button_width, 18, "+", button_colors, function() change_zoom(1) end)
local keyboard = KeyboardManager.new({close = request_close, open = request_open, save = request_save,
    zoom = change_zoom, tool_key = tool_key})

function init(saved, explicit_args)
    local path = explicit_args and os.path(launch_path) or saved and saved.path
    local message
    local view = not explicit_args and saved
    if path then
        local opened
        opened, message = open_image(path, view)
        if not opened and saved and saved.path and saved.path ~= path then
            if open_image(saved.path, saved) then view = saved end
        end
    end
    if document and view and view.tool == "pen" then tools:set_active(pen) end
    update_status(message)
    draw()
end

function update()
    local contacts = input.touch()
    local touch = contacts[1]
    local press = not touch_held and touch or nil
    touch_held = touch ~= nil
    if keyboard:update() then press = nil end

    if open_button:press(press) or save_button:press(press) then return end
    if tool_panel:press(press) then
        draw()
        return
    end
    if not document then return end
    if zoom_out_button:press(press) or zoom_in_button:press(press) then return end
    if tools:update_touch(contacts, press) then draw() end
end

function save_state()
    if not document then return end
    return {path = document.path, zoom = canvas.zoom, pan_x = canvas.pan_x, pan_y = canvas.pan_y,
        edits = canvas.edits, cursor_x = pen.x, cursor_y = pen.y, tool = tools.active == pen and "pen" or "pan"}
end

function deinit()
    tools:cancel_drag()
    tool_panel:close()
    canvas:close()
    close_document()
end
