local PanTool = {icon_path = "spr/pan.png"}

local arrow_step = 8
local arrows = {
    left = {-arrow_step, 0}, right = {arrow_step, 0},
    up = {0, -arrow_step}, down = {0, arrow_step},
}

function PanTool:drag(canvas, motion)
    return canvas:pan_by(motion.dx, motion.dy)
end

function PanTool:key_pressed(canvas, key)
    local delta = arrows[key]
    if delta then return canvas:pan_by(delta[1], delta[2]) end
end

return PanTool
