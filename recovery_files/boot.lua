-- recovery bootloader

sys.set_led_brightness(10)
sys.set_led(1, 0, 0, 255)
sys.set_led(2, 0, 0, 0)

local chunk, err = loadfile("/recovery/bench.lua", "t", _ENV)
if not chunk then
    error(err, 0)
end

chunk()

sys.set_led(1, 255, 128, 40)