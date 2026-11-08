#include "lua/module_definition.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "gfx.hpp"
#include "sprite.hpp"

extern "C" {
    #include "lauxlib.h"
    #include "lua.h"
}

namespace gfx {
namespace {

constexpr const char* sprite_type = "gfx.Sprite";

int release_sprite(lua_State* state)
{
    auto** sprite = static_cast<Sprite**>(luaL_checkudata(state, 1, sprite_type));
    delete *sprite;
    *sprite = nullptr;
    return 0;
}

Sprite& check_sprite(lua_State* state, int index)
{
    auto** sprite = static_cast<Sprite**>(luaL_checkudata(state, index, sprite_type));
    luaL_argcheck(state, *sprite != nullptr, index, "sprite is closed");
    return **sprite;
}

int sprite_get_pixel(lua_State* state);

int sprite_index(lua_State* state)
{
    const char* key = luaL_checkstring(state, 2);
    if (std::strcmp(key, "close") == 0) {
        lua_pushcfunction(state, release_sprite);
        return 1;
    }
    auto& sprite = check_sprite(state, 1);
    if (std::strcmp(key, "pget") == 0) {
        lua_pushcfunction(state, sprite_get_pixel);
    } else if (std::strcmp(key, "width") == 0) {
        lua_pushinteger(state, sprite.canvas.width());
    } else if (std::strcmp(key, "height") == 0) {
        lua_pushinteger(state, sprite.canvas.height());
    } else {
        lua_pushnil(state);
    }
    return 1;
}

int load_sprite(lua_State* state)
{
    size_t length;
    const char* path = luaL_checklstring(state, 1, &length);
    luaL_argcheck(state, std::strlen(path) == length, 1, "invalid PNG path");

    // Install the finalizer before owning any C++ resources: Lua can longjmp on OOM.
    auto** sprite = static_cast<Sprite**>(lua_newuserdatauv(state, sizeof(Sprite*), 0));
    *sprite = nullptr;
    luaL_setmetatable(state, sprite_type);
    const char* error = nullptr;
    *sprite = load_png(path, error);
    if (!*sprite) {
        lua_pushnil(state);
        lua_pushstring(state, error);
        return 2;
    }
    return 1;
}

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

int sprite_get_pixel(lua_State* state)
{
    auto& sprite = check_sprite(state, 1);
    const auto x = coordinate(state, 2);
    const auto y = coordinate(state, 3);
    lua_pushinteger(state, sprite.canvas.readPixel(x, y));
    return 1;
}

int dimension(lua_State* state, int index)
{
    const auto value = luaL_checkinteger(state, index);
    luaL_argcheck(state, value > 0 && value <= INT16_MAX, index,
                  "expected a positive dimension up to 32767");
    return static_cast<int>(value);
}

int circle_radius(lua_State* state)
{
    const auto value = luaL_checkinteger(state, 3);
    luaL_argcheck(state, value >= 0 && value <= INT16_MAX, 3,
                  "expected a radius from 0 to 32767");
    return static_cast<int>(value);
}

int ellipse_radius(lua_State* state, int index)
{
    // M5GFX's ellipse rasterizer uses 32-bit products of a radius and a squared radius.
    const auto value = luaL_checkinteger(state, index);
    luaL_argcheck(state, value >= 0 && value <= 512, index,
                  "expected an ellipse radius from 0 to 512");
    return static_cast<int>(value);
}

uint16_t check_color(lua_State* state, int index)
{
    const auto value = luaL_checkinteger(state, index);
    luaL_argcheck(state, value >= 0 && value <= UINT16_MAX, index,
                  "expected an RGB565 color");
    return static_cast<uint16_t>(value);
}

uint16_t drawing_color(lua_State* state, int index)
{
    return lua_isnoneornil(state, index) ? gfx::get_color() : check_color(state, index);
}

int spr(lua_State* state)
{
    auto& sprite = check_sprite(state, 1);
    const auto x = coordinate(state, 2);
    const auto y = coordinate(state, 3);
    if (lua_isnoneornil(state, 4)) {
        sprite.canvas.pushSprite(&canvas(state), x, y);
    } else {
        const auto transparent = check_color(state, 4);
        sprite.canvas.pushSprite(&canvas(state), x, y, transparent);
    }
    return 0;
}

uint8_t check_channel(lua_State* state, int index)
{
    const auto value = luaL_checkinteger(state, index);
    luaL_argcheck(state, value >= 0 && value <= UINT8_MAX, index,
                  "expected an RGB channel from 0 to 255");
    return static_cast<uint8_t>(value);
}

int rgb(lua_State* state)
{
    const auto count = lua_gettop(state);
    if (count == 1) {
        const lgfx::rgb565_t color(check_color(state, 1));
        lua_pushinteger(state, color.R8());
        lua_pushinteger(state, color.G8());
        lua_pushinteger(state, color.B8());
        return 3;
    }
    if (count != 3) {
        return luaL_error(state, "expected one RGB565 color or three RGB channels");
    }

    const auto red = check_channel(state, 1);
    const auto green = check_channel(state, 2);
    const auto blue = check_channel(state, 3);
    lua_pushinteger(state, lgfx::color565(red, green, blue));
    return 1;
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

int set_pixel(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    const auto color = drawing_color(state, 3);
    canvas(state).drawPixel(x, y, color);
    return 0;
}

int get_pixel(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    lua_pushinteger(state, canvas(state).readPixel(x, y));
    return 1;
}

int circle(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    const auto radius = circle_radius(state);
    const auto color = drawing_color(state, 4);
    canvas(state).drawCircle(x, y, radius, color);
    return 0;
}

int fill_circle(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    const auto radius = circle_radius(state);
    const auto color = drawing_color(state, 4);
    canvas(state).fillCircle(x, y, radius, color);
    return 0;
}

int ellipse(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    const auto rx = ellipse_radius(state, 3);
    const auto ry = ellipse_radius(state, 4);
    const auto color = drawing_color(state, 5);
    canvas(state).drawEllipse(x, y, rx, ry, color);
    return 0;
}

int fill_ellipse(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    const auto rx = ellipse_radius(state, 3);
    const auto ry = ellipse_radius(state, 4);
    const auto color = drawing_color(state, 5);
    canvas(state).fillEllipse(x, y, rx, ry, color);
    return 0;
}

int fill_rect(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    const auto width = dimension(state, 3);
    const auto height = dimension(state, 4);
    const auto color = drawing_color(state, 5);
    canvas(state).fillRect(x, y, width, height, color);
    return 0;
}

int rect(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    const auto width = dimension(state, 3);
    const auto height = dimension(state, 4);
    const auto color = drawing_color(state, 5);
    canvas(state).drawRect(x, y, width, height, color);
    return 0;
}

int line(lua_State* state)
{
    const auto x1 = coordinate(state, 1);
    const auto y1 = coordinate(state, 2);
    const auto x2 = coordinate(state, 3);
    const auto y2 = coordinate(state, 4);
    const auto color = drawing_color(state, 5);
    auto& target = canvas(state);

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
    const auto color = drawing_color(state, 4);
    auto& target = canvas(state);
    target.setTextColor(color);
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
    if (luaL_newmetatable(state, sprite_type)) {
        lua_pushcfunction(state, release_sprite);
        lua_setfield(state, -2, "__gc");
        lua_pushcfunction(state, release_sprite);
        lua_setfield(state, -2, "__close");
        lua_pushcfunction(state, sprite_index);
        lua_setfield(state, -2, "__index");
        lua_pushstring(state, sprite_type);
        lua_setfield(state, -2, "__metatable");
    }
    lua_pop(state, 1);
    const luaL_Reg functions[] = {
        {"load_sprite", load_sprite},
        {"spr", spr},
        {"cls", clear},
        {"flip", swap_canvas},
        {"presenter_fps", presenter_fps},
        {"color", set_color},
        {"rgb", rgb},
        {"pset", set_pixel},
        {"pget", get_pixel},
        {"circ", circle},
        {"circfill", fill_circle},
        {"oval", ellipse},
        {"ovalfill", fill_ellipse},
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
