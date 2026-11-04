#include "system.hpp"

#include "M5Unified.h"
#include "esp_heap_caps.h"
#include "lua/module_definition.hpp"
#include "unit/unit_Tab5Keyboard.hpp"

#include <sys/time.h>
#include <time.h>

extern "C" {
#include "lauxlib.h"
}

namespace tabos::system {
namespace {

m5::I2C_Class keyboard_bus;
m5::unit::UnitTab5Keyboard keyboard;
bool keyboard_bus_open = false;
bool keyboard_attached = false;

bool enable_custom_rgb()
{
    // Reapply the mode in case the keyboard was connected or reset after boot.
    return attached_keyboard() && keyboard.writeRgbMode(m5::unit::tab5_keyboard::RgbMode::Custom);
}

uint8_t check_range(lua_State* state, int index, int min, int max, const char* message)
{
    const auto value = luaL_checkinteger(state, index);
    luaL_argcheck(state, value >= min && value <= max, index, message);
    return static_cast<uint8_t>(value);
}

int set_keyboard_led(lua_State* state)
{
    const auto led = check_range(state, 1, 1, 2, "expected LED 1 (left) or 2 (right)");
    const auto red = check_range(state, 2, 0, 255, "expected red in 0..255");
    const auto green = check_range(state, 3, 0, 255, "expected green in 0..255");
    const auto blue = check_range(state, 4, 0, 255, "expected blue in 0..255");
    lua_pushboolean(state, enable_custom_rgb() && keyboard.writeRgb(led - 1, red, green, blue));
    return 1;
}

int set_keyboard_led_brightness(lua_State* state)
{
    const auto percent = check_range(state, 1, 0, 100, "expected brightness in 0..100");
    lua_pushboolean(state, enable_custom_rgb() && keyboard.writeBrightness(percent));
    return 1;
}

int push_memory(lua_State* state, uint32_t caps)
{
    const auto total = heap_caps_get_total_size(caps);
    const auto free = heap_caps_get_free_size(caps);
    lua_pushinteger(state, total - free);
    lua_pushinteger(state, total);
    return 2;
}

int sram(lua_State* state)
{
    return push_memory(state, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
}

int psram(lua_State* state)
{
    return push_memory(state, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
}

int battery_level(lua_State* state)
{
    const auto level = M5.Power.getBatteryLevel();
    if (level < 0) {
        lua_pushnil(state);
    } else {
        lua_pushinteger(state, level);
    }
    return 1;
}

int is_charging(lua_State* state)
{
    const auto status = M5.Power.isCharging();
    if (status == m5::Power_Class::charge_unknown) {
        lua_pushnil(state);
    } else {
        lua_pushboolean(state, status == m5::Power_Class::is_charging);
    }
    return 1;
}

int get_time(lua_State* state)
{
    lua_pushinteger(state, time(nullptr));
    return 1;
}

int set_time(lua_State* state)
{
    // The Tab5 RTC represents years 2000 through 2099.
    const auto timestamp = luaL_checkinteger(state, 1);
    luaL_argcheck(state, timestamp >= 946684800LL && timestamp < 4102444800LL, 1,
                  "expected Unix seconds in UTC years 2000 through 2099");
    const time_t epoch = timestamp;
    struct tm utc{};
    if (!gmtime_r(&epoch, &utc)) {
        return luaL_error(state, "could not convert timestamp to UTC");
    }

    // Use the driver to get the write result before changing the system clock.
    auto* rtc = M5.Rtc.getRtcInstancePtr();
    const m5::rtc_datetime_t date_time{utc};
    if (!rtc || !rtc->setDateTime(&date_time.date, &date_time.time)) {
        return luaL_error(state, "could not update hardware RTC");
    }

    const timeval clock_time{epoch, 0};
    if (settimeofday(&clock_time, nullptr) != 0) {
        return luaL_error(state, "RTC updated but could not set system time");
    }
    return 0;
}

int push_system_table(lua_State* state)
{
    const luaL_Reg functions[] = {
        {"set_led", set_keyboard_led},
        {"set_led_brightness", set_keyboard_led_brightness},
        {"sram", sram},
        {"psram", psram},
        {"bat_lvl", battery_level},
        {"bat_chrg", is_charging},
        {"get_time", get_time},
        {"set_time", set_time},
        {nullptr, nullptr},
    };
    luaL_newlib(state, functions);
    return 1;
}

}

m5::unit::UnitTab5Keyboard* attached_keyboard()
{
    // The Tab5 keyboard is on Ext.Port1 (SDA GPIO0, SCL GPIO1).
    if (!keyboard_bus_open) {
        keyboard_bus_open = keyboard_bus.begin(I2C_NUM_0, 0, 1);
    }
    if (keyboard_bus_open && !keyboard_attached) {
        auto config = keyboard.component_config();
        config.clock = 100000;
        keyboard.component_config(config);
        keyboard_attached = keyboard.assign(keyboard_bus);
    }
    return keyboard_attached ? &keyboard : nullptr;
}

bool init()
{
    return enable_custom_rgb();
}

lua_vm::Module lua_module()
{
    static const lua_vm::Module::Definition definition{"sys", push_system_table};
    return lua_vm::Module{definition};
}

}
