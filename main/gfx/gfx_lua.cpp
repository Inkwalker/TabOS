#include "lua/module_definition.hpp"

#include "gfx.hpp"

#include <algorithm>
#include <cstdlib>

extern "C" {
    #include "lauxlib.h"
    #include "lua.h"
}

namespace gfx {
namespace {

M5Canvas& canvas(lua_State* state)
{
    auto* target = gfx::active_canvas();
    if (!target) {
        luaL_error(state, "gfx has no active canvas");
    }
    return *target;
}

int coordinate(lua_State* state, int index)
{
    const auto value = luaL_checkinteger(state, index);
    luaL_argcheck(state, value >= INT16_MIN && value <= INT16_MAX, index,
                  "coordinate out of range");
    return static_cast<int>(value);
}

int dimension(lua_State* state, int index)
{
    const auto value = luaL_checkinteger(state, index);
    luaL_argcheck(state, value > 0 && value <= INT16_MAX, index,
                  "expected a positive dimension up to 32767");
    return static_cast<int>(value);
}

uint16_t check_color(lua_State* state, int index)
{
    const auto value = luaL_checkinteger(state, index);
    luaL_argcheck(state, value >= 0 && value <= UINT16_MAX, index,
                  "expected an RGB565 color");
    return static_cast<uint16_t>(value);
}

int clear(lua_State* state)
{
    const uint16_t color = lua_isnoneornil(state, 1) ? 0 : check_color(state, 1);
    canvas(state).fillScreen(color);
    return 0;
}

int set_color(lua_State* state)
{
    gfx::set_color(check_color(state, 1));
    return 0;
}

int fill_rect(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    const auto width = dimension(state, 3);
    const auto height = dimension(state, 4);
    canvas(state).fillRect(x, y, width, height, gfx::get_color());
    return 0;
}

int rect(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    const auto width = dimension(state, 3);
    const auto height = dimension(state, 4);
    canvas(state).drawRect(x, y, width, height, gfx::get_color());
    return 0;
}

int line(lua_State* state)
{
    const auto x1 = coordinate(state, 1);
    const auto y1 = coordinate(state, 2);
    const auto x2 = coordinate(state, 3);
    const auto y2 = coordinate(state, 4);
    auto& target = canvas(state);
    const auto color = gfx::get_color();

    if (y1 == y2) {
        target.drawFastHLine(std::min(x1, x2), y1, std::abs(x2 - x1) + 1, color);
    } else if (x1 == x2) {
        target.drawFastVLine(x1, std::min(y1, y2), std::abs(y2 - y1) + 1, color);
    } else {
        target.drawLine(x1, y1, x2, y2, color);
    }
    return 0;
}

int text(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    size_t length;
    const auto* value = luaL_checklstring(state, 3, &length);
    auto& target = canvas(state);
    target.setTextColor(gfx::get_color());
    target.setCursor(x, y);
    target.write(reinterpret_cast<const uint8_t*>(value), length);
    return 0;
}
int swap_canvas(lua_State* state)
{
    if (!gfx::swap_canvas()) {
        return luaL_error(state, "gfx has no active canvas");
    }
    return 0;
}

int presenter_fps(lua_State* state)
{
    lua_pushnumber(state, gfx::presenter_fps());
    return 1;
}

int push_gfx_table(lua_State* state)
{
    const auto& target = canvas(state);
    const luaL_Reg functions[] = {
        {"cls", clear},
        {"flip", swap_canvas},
        {"presenter_fps", presenter_fps},
        {"color", set_color},
        {"rectfill", fill_rect},
        {"rect", rect},
        {"line", line},
        {"print", text},
        {nullptr, nullptr},
    };

    luaL_newlib(state, functions);
    lua_pushinteger(state, target.width());
    lua_setfield(state, -2, "width");
    lua_pushinteger(state, target.height());
    lua_setfield(state, -2, "height");
    return 1;
}
} // namespace

lua_vm::Module lua_module()
{
    static const lua_vm::Module::Definition definition{"gfx", push_gfx_table};
    return lua_vm::Module{definition};
}

} // namespace gfx
