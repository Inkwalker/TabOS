#include "M5Unified.h"
#include "esp_log.h"
#include "gfx/gfx.hpp"
#include "input/input.hpp"
#include "lua/lua_vm.hpp"
#include "system/system.hpp"

extern "C" void app_main()
{
    auto config = M5.config();
    config.internal_imu = true;
    config.internal_rtc = true;
    config.internal_mic = false;
    config.internal_spk = false;
    config.external_display_value = 0;
    M5.begin(config);
    M5.Display.setBrightness(128);

    if (!tabos::system::init()) {
        ESP_LOGW("tabos", "Could not initialize keyboard LED custom mode");
    }

    if (!gfx::init()) {
        ESP_LOGE("tabos", "Could not initialize graphics");
        return;
    }

    if (!lua_vm::start({gfx::lua_module(), tabos::system::lua_module(), tabos::input::lua_module()})) {
        ESP_LOGE("tabos", "Could not start the Lua VM task");
    }
}
