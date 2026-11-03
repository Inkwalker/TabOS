#pragma once

#include "lua_vm.hpp"

extern "C" {
#include "lua.h"
}

namespace lua_vm {

struct Module::Definition {
    const char* name; // Static storage, e.g. a string literal.
    lua_CFunction push_table; // Leaves one table on the Lua stack and returns 1.
};

}
