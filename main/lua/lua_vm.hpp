#pragma once

#include <initializer_list>
#include <string_view>

namespace lua_vm {

enum class ScriptKind { File, Source };

class Module {
public:
    struct Definition;

    explicit Module(const Definition& definition) : definition_(definition) {}

private:
    const Definition& definition_;
    friend bool start(ScriptKind kind, std::string_view script, std::initializer_list<Module> modules);
};

// Copies the file path or Lua source and the module descriptors before starting
// a task pinned to the calling core. Returns whether the task was started.
// Installs modules in list order. Later entries replace globals with the same name.
bool start(ScriptKind kind, std::string_view script, std::initializer_list<Module> modules);
}
