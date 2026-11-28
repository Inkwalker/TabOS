#pragma once

struct lua_State;

namespace gfx {

void register_font_type(lua_State* state);
int create_font(lua_State* state);
int set_font(lua_State* state);

} // namespace gfx
