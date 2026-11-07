-- recovery bootloader

sys.set_led_brightness(10)
sys.set_led(1, 0, 0, 255)
sys.set_led(2, 0, 0, 0)

local sd_path = "/sd/system.lua"
local sd_started, sd_error = false, nil
input.update()
-- Del is row 1, column 14 on the Tab5 keyboard.
if input.key(1, 14) then
    sd_error = "Safe boot requested"
elseif not fs.stat("/sd") then
    sd_error = "SD card is not mounted"
elseif not fs.stat(sd_path) then
    sd_error = "Missing " .. sd_path
else
    local chunk, load_error = loadfile(sd_path, "t", _ENV)
    if chunk then
        sd_started, sd_error = pcall(chunk)
    else
        sd_error = load_error
    end
end

if not sd_started then
    local chunk, err = loadfile("/rec/system.lua", "t", _ENV)
    if not chunk then
        error(err, 0)
    end
    chunk(sd_error)
end

sys.set_led(1, 0, 255, 0)
