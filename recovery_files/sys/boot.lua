-- recovery bootloader

gfx.cls()
local logo = gfx.load_sprite("/rec/sys/spr/logo.png")
if logo then
    gfx.spr(logo, math.floor((gfx.width - logo.width) / 2), math.floor((gfx.height - logo.height) / 2))
    logo:close()
end
local hint = "Press Del for recovery"
gfx.print(math.floor((gfx.width - #hint * 6) / 2), gfx.height - 12, hint, gfx.rgb(220, 230, 240))
gfx.flip()

sys.set_led_brightness(10)
sys.set_led(1, 0, 0, 255)
sys.set_led(2, 0, 0, 0)

local sd_path = "/sd/sys/system.lua"
local base_package_path = package.path
local sd_started, sd_error = false, nil
local safe_boot, beep_until = false, nil
-- Poll throughout the window, including after the input module's 1s retry.
for elapsed = 0, 2975, 25 do
    input.update()
    if beep_until and elapsed >= beep_until then
        if audio.stop(1) then beep_until = nil end
    end
    -- Del is row 1, column 14. Latch the first detected press for this boot.
    if not safe_boot and (input.keyp(1, 14) or input.key(1, 14)) then
        safe_boot = true
        if audio.set_volume(1, 0.2) and audio.start(1, 880, "sine") then
            beep_until = elapsed + 100
        end
    end
    sys.sleep(25)
end
-- A press near the end of the window gets a shorter beep before handoff.
if beep_until then audio.stop(1) end
if safe_boot then
    sd_error = "Safe boot requested"
elseif not fs.stat("/sd") then
    sd_error = "SD card is not mounted"
elseif not fs.stat(sd_path) then
    sd_error = "Missing " .. sd_path
else
    local chunk, load_error = loadfile(sd_path, "t", _ENV)
    if chunk then
        package.path = "/sd/sys/?.lua;" .. base_package_path
        sd_started, sd_error = pcall(chunk)
    else
        sd_error = load_error
    end
end

if not sd_started then
    package.path = "/rec/sys/?.lua;" .. base_package_path
    local chunk, err = loadfile("/rec/sys/system.lua", "t", _ENV)
    if not chunk then
        error(err, 0)
    end
    chunk(sd_error)
end

sys.set_led(1, 0, 255, 0)
