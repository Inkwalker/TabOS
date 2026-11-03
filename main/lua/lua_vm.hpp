#pragma once

#include <initializer_list>

namespace lua_vm {

class Module {
public:
    struct Definition;

    explicit Module(const Definition& definition) : definition_(definition) {}

private:
    const Definition& definition_;
    friend bool start(std::initializer_list<Module> modules);
};

// Copies the descriptors and starts boot.lua on a task pinned to the calling core.
// Installs modules in list order. Later entries replace globals with the same name.
bool start(std::initializer_list<Module> modules);
}
