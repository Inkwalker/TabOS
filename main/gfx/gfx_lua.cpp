#include "lua/module_definition.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "gfx.hpp"
#include "commands.hpp"
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
    if (*sprite) gfx::wait_commands();
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

lgfx::PPA_Sprite& canvas(lua_State* state)
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

int create_sprite(lua_State* state)
{
    const int width = dimension(state, 1);
    const int height = dimension(state, 2);
    auto** sprite = static_cast<Sprite**>(lua_newuserdatauv(state, sizeof(Sprite*), 0));
    *sprite = nullptr;
    luaL_setmetatable(state, sprite_type);
    const char* error = nullptr;
    *sprite = gfx::create_sprite(width, height, error);
    if (!*sprite) {
        lua_pushnil(state);
        lua_pushstring(state, error);
        return 2;
    }
    return 1;
}

int select_target(lua_State* state)
{
    const int width = lua_gettop(state) == 0 ? canvas_width : dimension(state, 1);
    const int height = lua_gettop(state) == 0 ? canvas_height : dimension(state, 2);
    luaL_argcheck(state, size_t(width) * height * sizeof(uint16_t) <= target_capacity,
                  1, "target exceeds 128 KiB");
    canvas(state);
    const auto result = execute_and_wait(DrawCommand{DrawOp::target, {width, height}});
    if (result != ESP_OK) return luaL_error(state, "gfx.target failed (%s)", esp_err_to_name(result));
    return 0;
}

int gfx_index(lua_State* state)
{
    const char* key = lua_type(state, 2) == LUA_TSTRING ? lua_tostring(state, 2) : "";
    if (std::strcmp(key, "width") == 0) {
        lua_pushinteger(state, canvas(state).width());
    } else if (std::strcmp(key, "height") == 0) {
        lua_pushinteger(state, canvas(state).height());
    } else {
        lua_pushnil(state);
    }
    return 1;
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
    const bool flip_x = lua_toboolean(state, 5);
    const bool flip_y = lua_toboolean(state, 6);
    const int32_t transparent = lua_isnoneornil(state, 4) ? -1 : check_color(state, 4);
    canvas(state);
    DrawCommand command{DrawOp::sprite, {x, y}};
    command.sprite = &sprite.canvas;
    command.transparent = transparent;
    command.flip_x = flip_x;
    command.flip_y = flip_y;
    enqueue(command);
    return 0;
}

int sspr(lua_State* state)
{
    auto& sprite = check_sprite(state, 1);
    const auto sx = coordinate(state, 2);
    const auto sy = coordinate(state, 3);
    const auto sw = dimension(state, 4);
    const auto sh = dimension(state, 5);
    const auto dx = coordinate(state, 6);
    const auto dy = coordinate(state, 7);
    const auto dw = lua_isnoneornil(state, 8) ? sw : dimension(state, 8);
    const auto dh = lua_isnoneornil(state, 9) ? sh : dimension(state, 9);
    const int32_t key = lua_isnoneornil(state, 10) ? -1 : check_color(state, 10);
    const bool flip_x = lua_toboolean(state, 11);
    const bool flip_y = lua_toboolean(state, 12);
    canvas(state);
    DrawCommand command{DrawOp::sprite_region, {sx, sy, sw, sh, dx, dy, dw, dh}};
    command.sprite = &sprite.canvas;
    command.transparent = key;
    command.flip_x = flip_x;
    command.flip_y = flip_y;
    enqueue(command);
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
    auto& target = canvas(state);
    DrawCommand command{DrawOp::fill_rect, {0, 0, int(target.width()), int(target.height())}};
    command.color = color;
    enqueue(command);
    return 0;
}

int set_color(lua_State* state)
{
    gfx::set_color(check_color(state, 1));
    return 0;
}

int clip(lua_State* state)
{
    if (lua_gettop(state) == 0) {
        canvas(state);
        enqueue(DrawCommand{DrawOp::reset_clip});
        return 0;
    }
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    const auto width = dimension(state, 3);
    const auto height = dimension(state, 4);
    canvas(state);
    enqueue(DrawCommand{DrawOp::clip, {x, y, width, height}});
    return 0;
}

int set_pixel(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    const auto color = drawing_color(state, 3);
    canvas(state);
    DrawCommand command{DrawOp::pixel, {x, y}};
    command.color = color;
    enqueue(command);
    return 0;
}

int get_pixel(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    canvas(state);
    uint16_t pixel;
    execute_and_wait(DrawCommand{DrawOp::pget, {x, y}}, &pixel);
    lua_pushinteger(state, pixel);
    return 1;
}

int circle(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    const auto radius = circle_radius(state);
    const auto color = drawing_color(state, 4);
    canvas(state);
    DrawCommand command{DrawOp::circle, {x, y, radius}};
    command.color = color;
    enqueue(command);
    return 0;
}

int fill_circle(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    const auto radius = circle_radius(state);
    const auto color = drawing_color(state, 4);
    canvas(state);
    DrawCommand command{DrawOp::fill_circle, {x, y, radius}};
    command.color = color;
    enqueue(command);
    return 0;
}

int ellipse(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    const auto rx = ellipse_radius(state, 3);
    const auto ry = ellipse_radius(state, 4);
    const auto color = drawing_color(state, 5);
    canvas(state);
    DrawCommand command{DrawOp::ellipse, {x, y, rx, ry}};
    command.color = color;
    enqueue(command);
    return 0;
}

int fill_ellipse(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    const auto rx = ellipse_radius(state, 3);
    const auto ry = ellipse_radius(state, 4);
    const auto color = drawing_color(state, 5);
    canvas(state);
    DrawCommand command{DrawOp::fill_ellipse, {x, y, rx, ry}};
    command.color = color;
    enqueue(command);
    return 0;
}

int fill_rect(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    const auto width = dimension(state, 3);
    const auto height = dimension(state, 4);
    const auto color = drawing_color(state, 5);
    canvas(state);
    DrawCommand command{DrawOp::fill_rect, {x, y, width, height}};
    command.color = color;
    enqueue(command);
    return 0;
}

int rect(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    const auto width = dimension(state, 3);
    const auto height = dimension(state, 4);
    const auto color = drawing_color(state, 5);
    canvas(state);
    DrawCommand command{DrawOp::rect, {x, y, width, height}};
    command.color = color;
    enqueue(command);
    return 0;
}

int line(lua_State* state)
{
    const auto x1 = coordinate(state, 1);
    const auto y1 = coordinate(state, 2);
    const auto x2 = coordinate(state, 3);
    const auto y2 = coordinate(state, 4);
    const auto color = drawing_color(state, 5);
    canvas(state);
    DrawCommand command{DrawOp::line, {x1, y1, x2, y2}};
    command.color = color;
    enqueue(command);
    return 0;
}

double source_number(lua_State* state, int index)
{
    const double value = luaL_checknumber(state, index);
    luaL_argcheck(state, std::isfinite(value), index, "expected a finite source coordinate or step");
    return value;
}

int tline(lua_State* state)
{
    auto& sprite = check_sprite(state, 1);
    const int x0 = coordinate(state, 2);
    const int y0 = coordinate(state, 3);
    const int x1 = coordinate(state, 4);
    const int y1 = coordinate(state, 5);
    const double sx = source_number(state, 6);
    const double sy = source_number(state, 7);
    const double sdx = source_number(state, 8);
    const double sdy = source_number(state, 9);
    canvas(state);
    DrawCommand command{DrawOp::textured_line, {x0, y0, x1, y1}};
    command.sprite = &sprite.canvas;
    command.payload.source[0] = sx;
    command.payload.source[1] = sy;
    command.payload.source[2] = sdx;
    command.payload.source[3] = sdy;
    enqueue(command);
    return 0;
}

int text(lua_State* state)
{
    const auto x = coordinate(state, 1);
    const auto y = coordinate(state, 2);
    size_t length;
    const auto* value = luaL_checklstring(state, 3, &length);
    const auto color = drawing_color(state, 4);
    canvas(state);
    DrawCommand command{DrawOp::text, {x, y}};
    command.color = color;
    // Queue-owned chunks never retain a pointer into the Lua heap.
    do {
        const size_t count = std::min(length, sizeof(command.payload.text));
        std::memcpy(command.payload.text, value, count);
        command.args[2] = static_cast<int>(count);
        enqueue(command);
        command.op = DrawOp::text_continue;
        value += count;
        length -= count;
    } while (length);
    return 0;
}
int swap_canvas(lua_State* state)
{
    auto& target = canvas(state);
    DrawCommand command{DrawOp::flip};
    if (!lua_isnoneornil(state, 1)) {
        auto& sprite = check_sprite(state, 1);
        luaL_argcheck(state, sprite.canvas.width() == target.width()
                      && sprite.canvas.height() == target.height(), 1,
                      "sprite dimensions must match the active target");
        command.op = DrawOp::save;
        command.sprite = &sprite.canvas;
    }
    const auto result = execute_and_wait(command);
    if (result != ESP_OK) {
        return luaL_error(state, "gfx.flip failed (%s)", esp_err_to_name(result));
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
    canvas(state);
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
        {"create_sprite", create_sprite},
        {"target", select_target},
        {"spr", spr},
        {"sspr", sspr},
        {"cls", clear},
        {"flip", swap_canvas},
        {"presenter_fps", presenter_fps},
        {"color", set_color},
        {"clip", clip},
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
        {"tline", tline},
        {"print", text},
        {nullptr, nullptr},
    };

    luaL_newlib(state, functions);
    lua_newtable(state);
    lua_pushcfunction(state, gfx_index);
    lua_setfield(state, -2, "__index");
    lua_setmetatable(state, -2);
    return 1;
}
} // namespace

lua_vm::Module lua_module()
{
    static const lua_vm::Module::Definition definition{"gfx", push_gfx_table};
    return lua_vm::Module{definition};
}

} // namespace gfx
