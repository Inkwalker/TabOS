#pragma once

#include "lua/lua_vm.hpp"

namespace tabos::system {

bool init();
lua_vm::Module lua_module();

}
