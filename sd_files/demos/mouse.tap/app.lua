local colors = {
    background = gfx.rgb(14, 21, 31),
    panel = gfx.rgb(24, 36, 50),
    grid = gfx.rgb(32, 49, 65),
    border = gfx.rgb(62, 86, 104),
    text = gfx.rgb(232, 242, 250),
    muted = gfx.rgb(153, 176, 194),
    accent = gfx.rgb(107, 230, 205),
    outline = gfx.rgb(6, 12, 20),
}

local read_mouse = input.mouse
local pointer_speed = 0.5 -- Canvas pixels per device count.
local pointer_key = gfx.rgb(255, 0, 255)
local pointer
local width, height = gfx.width, gfx.height
local pad = {x = 12, y = 43, w = width - 122, h = height - 55}
local panel_x = pad.x + pad.w + 8
local panel_w = width - panel_x - 12
local target = {x = pad.x + (pad.w - 88) // 2, y = pad.y + (pad.h - 36) // 2, w = 88, h = 36}
local exit = {x = width - 50, y = 8, w = 38, h = 18}
local x, y = pad.x + pad.w // 2, pad.y + 18
local hits, wheel = 0, 0
local buttons = {
    {label = "L", mask = 1, flash = 0},
    {label = "M", mask = 4, flash = 0},
    {label = "R", mask = 2, flash = 0},
    {label = "4", mask = 8, flash = 0},
    {label = "5", mask = 16, flash = 0},
}

local function contains(box, px, py)
    return px >= box.x and py >= box.y and px < box.x + box.w and py < box.y + box.h
end

local function draw_box(box, hovered)
    gfx.rectfill(box.x, box.y, box.w, box.h, colors.panel)
    gfx.rect(box.x, box.y, box.w, box.h, hovered and colors.accent or colors.border)
end

local function draw(mouse)
    local connected = mouse and mouse.connected
    local held = mouse and mouse.buttons or 0
    local px, py = math.floor(x), math.floor(y)
    gfx.cls(colors.background)
    gfx.print(12, 11, "MOUSE POINTER", colors.text)
    local status = connected and "USB-A connected" or (read_mouse and "Plug in a USB-A mouse" or "Update TabOS for USB mouse")
    gfx.print(12, 27, status, connected and colors.accent or colors.muted)
    draw_box(exit, connected and contains(exit, px, py))
    gfx.print(exit.x + 7, exit.y + 5, "Exit", colors.text)

    for gx = pad.x + 16, pad.x + pad.w - 2, 16 do
        gfx.line(gx, pad.y + 1, gx, pad.y + pad.h - 2, colors.grid)
    end
    for gy = pad.y + 16, pad.y + pad.h - 2, 16 do
        gfx.line(pad.x + 1, gy, pad.x + pad.w - 2, gy, colors.grid)
    end
    gfx.rect(pad.x, pad.y, pad.w, pad.h, colors.border)
    draw_box(target, connected and contains(target, px, py))
    gfx.print(target.x + 8, target.y + 6, "Click target", colors.text)
    gfx.print(target.x + 8, target.y + 21, "Hits: " .. hits, colors.accent)

    gfx.rectfill(panel_x, pad.y, panel_w, pad.h, colors.panel)
    gfx.print(panel_x + 7, pad.y + 8, "POSITION", colors.muted)
    local position = connected and string.format("%03d, %03d", px, py) or "---, ---"
    gfx.print(panel_x + 7, pad.y + 21, position, colors.text)
    gfx.print(panel_x + 7, pad.y + 42, "WHEEL TOTAL", colors.muted)
    gfx.print(panel_x + 7, pad.y + 55, string.format("%+d", wheel), colors.accent)
    gfx.print(panel_x + 7, pad.y + 76, "BUTTONS", colors.muted)
    for i, button in ipairs(buttons) do
        local bx = panel_x + 7 + (i - 1) * 14
        local by = pad.y + 89
        local down = (held & button.mask) ~= 0
        gfx.rectfill(bx, by, 12, 17, down and colors.accent or colors.background)
        gfx.rect(bx, by, 12, 17, button.flash > 0 and colors.accent or colors.border)
        gfx.print(bx + 3, by + 5, button.label, down and colors.outline or colors.text)
    end

    if connected then
        gfx.spr(pointer, px, py, pointer_key)
        if held ~= 0 then gfx.pset(px, py, colors.accent) end
    end
end

function init()
    pointer = assert(gfx.load_sprite(os.path("pointer.png")))
    gfx.fill_pattern()
    draw(read_mouse and read_mouse())
end

function update(dt)
    if input.keyp(1, 1) then
        os.exit()
        return
    end
    for _, touch in ipairs(input.touch()) do
        if contains(exit, touch.x, touch.y) then
            os.exit()
            return
        end
    end

    local mouse = read_mouse and read_mouse()
    if mouse and mouse.connected then
        x = math.max(0, math.min(width - 1, x + mouse.dx * pointer_speed))
        y = math.max(0, math.min(height - 1, y + mouse.dy * pointer_speed))
        wheel = wheel + mouse.wheel
        if (mouse.pressed & 1) ~= 0 then
            local px, py = math.floor(x), math.floor(y)
            if contains(exit, px, py) then
                os.exit()
                return
            end
            if contains(target, px, py) then hits = hits + 1 end
        end
    end

    local changed = mouse and (mouse.pressed | mouse.released) or 0
    for _, button in ipairs(buttons) do
        button.flash = (changed & button.mask) ~= 0 and 0.18 or math.max(0, button.flash - dt)
    end
    draw(mouse)
end

function deinit()
    if pointer then pointer:close() end
end
