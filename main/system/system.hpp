#pragma once

#include "lua/lua_vm.hpp"

namespace m5::unit {
class UnitTab5Keyboard;
}

namespace tabos::system {

bool init();
m5::unit::UnitTab5Keyboard* attached_keyboard();
lua_vm::Module lua_module();

}
