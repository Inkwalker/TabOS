#pragma once

/* Private allocation tags, outside Lua's public object type tags. They are
 * passed as osize only for new blocks, as permitted by lua_Alloc. */
#define TABOS_LUA_ALLOC_STACK 0x100
#define TABOS_LUA_ALLOC_BYTECODE 0x101
#define TABOS_LUA_ALLOC_CONSTANTS 0x102
