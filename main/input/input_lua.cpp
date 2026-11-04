#include "input.hpp"

#include "esp_timer.h"
#include "gfx/gfx.hpp"
#include "lua/module_definition.hpp"
#include "system/system.hpp"
#include "unit/unit_Tab5Keyboard.hpp"
#include "utility/hid_keycode.hpp"

#include <array>

extern "C" {
#include "lauxlib.h"
}

namespace tabos::input {
namespace {

namespace keys = m5::unit::tab5_keyboard;
m5::unit::UnitTab5Keyboard* keyboard = nullptr;
int64_t next_keyboard_attempt = 0;
constexpr unsigned keyboard_fifo_size = 32;
constexpr unsigned keyboard_rows = keys::KEY_COUNT / keys::KEY_COL_COUNT;
std::array<char, 256> pending_text;
std::size_t pending_text_size = 0;

void update_keyboard()
{
    // Replay events against the pre-update state so modifiers apply in event order.
    auto held = keyboard->nowBits();
    keyboard->update();
    while (!keyboard->empty()) {
        const auto event = keyboard->oldest();
        keyboard->discard();
        if (event.type != keys::EventType::Key) {
            continue;
        }

        const auto [row, col, pressed] = event.key;
        if (row >= keyboard_rows || col >= keys::KEY_COL_COUNT) {
            continue;
        }
        held.set(keys::toKeyIndex(row, col), pressed);
        if (!pressed || keys::isModifierKey(row, col) || held.test(keys::KIDX_CTRL) || held.test(keys::KIDX_ALT)) {
            continue;
        }

        const auto mapping = held.test(keys::KIDX_SYM)
            ? keys::keyMatrixToHidSym(row, col)
            : keys::keyMatrixToHidBase(row, col);
        constexpr uint8_t left_shift = 0x02;
        const auto modifier = mapping.modifier | (held.test(keys::KIDX_AA) ? left_shift : 0);
        const auto character = keys::hidUsageToChar(mapping.keycode, modifier);
        if (character && pending_text_size < pending_text.size()) {
            pending_text[pending_text_size++] = character;
        }
    }
}

int update(lua_State*)
{
    M5.update();

    const auto now = esp_timer_get_time();
    if (!keyboard && now >= next_keyboard_attempt) {
        next_keyboard_attempt = now + 1000000;
        auto* device = system::attached_keyboard();
        if (device) {
            auto config = device->component_config();
            config.stored_size = keyboard_fifo_size;
            device->component_config(config);
            if (device->begin()) {
                keyboard = device;
            }
        }
    }
    if (keyboard) {
        update_keyboard();
    }
    return 0;
}

int touches(lua_State* state)
{
    const auto count = M5.Touch.getCount();
    lua_createtable(state, count, 0);
    unsigned seen_ids = 0;
    int index = 0;
    for (int i = 0; i < count; ++i) {
        const auto& touch = M5.Touch.getDetail(i);
        const auto id_bit = 1u << touch.id;
        // getCount() can include release states as well as active contacts.
        if (!touch.isPressed() || (seen_ids & id_bit)) {
            continue;
        }
        seen_ids |= id_bit;

        lua_createtable(state, 0, 3);
        lua_pushinteger(state, touch.id);
        lua_setfield(state, -2, "id");
        // Undo the presenter's landscape rotation and scale to the Lua canvas.
        lua_pushinteger(state, (gfx::screen_width - 1 - touch.y) / gfx::scale);
        lua_setfield(state, -2, "x");
        lua_pushinteger(state, touch.x / gfx::scale);
        lua_setfield(state, -2, "y");
        lua_rawseti(state, -2, ++index);
    }
    return 1;
}

template <bool (m5::unit::UnitTab5Keyboard::*query)(uint8_t) const>
int key_state(lua_State* state)
{
    const auto row = luaL_checkinteger(state, 1);
    const auto col = luaL_checkinteger(state, 2);
    luaL_argcheck(state, row >= 1 && row <= keyboard_rows, 1, "expected row 1..5");
    luaL_argcheck(state, col >= 1 && col <= keys::KEY_COL_COUNT, 2, "expected column 1..14");
    if (!keyboard) {
        lua_pushnil(state);
        return 1;
    }

    const auto index = keys::toKeyIndex(row - 1, col - 1);
    lua_pushboolean(state, (keyboard->*query)(index));
    return 1;
}

int read_text(lua_State* state)
{
    lua_pushlstring(state, pending_text.data(), pending_text_size);
    pending_text_size = 0;
    return 1;
}

template <bool (m5::IMU_Class::*read)(float*, float*, float*)>
int read_imu(lua_State* state)
{
    float x, y, z;
    if (!M5.Imu.isEnabled() || !(M5.Imu.*read)(&x, &y, &z)) {
        lua_pushnil(state);
        return 1;
    }

    lua_pushnumber(state, x);
    lua_pushnumber(state, y);
    lua_pushnumber(state, z);
    return 3;
}

int push_input_table(lua_State* state)
{
    const luaL_Reg functions[] = {
        {"update", update},
        {"touch", touches},
        {"key", key_state<&m5::unit::UnitTab5Keyboard::isPressed>},
        {"keyp", key_state<&m5::unit::UnitTab5Keyboard::wasPressed>},
        {"keyr", key_state<&m5::unit::UnitTab5Keyboard::wasReleased>},
        {"txt", read_text},
        {"accel", read_imu<&m5::IMU_Class::getAccel>},
        {"gyro", read_imu<&m5::IMU_Class::getGyro>},
        {nullptr, nullptr},
    };
    luaL_newlib(state, functions);
    return 1;
}

}

lua_vm::Module lua_module()
{
    static const lua_vm::Module::Definition definition{"input", push_input_table};
    return lua_vm::Module{definition};
}

}
