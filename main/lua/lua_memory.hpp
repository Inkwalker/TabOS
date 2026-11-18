#pragma once

#include <cstddef>

namespace lua_vm::memory {

// Ordinary objects leave this much of the shared SRAM budget available for
// VM stacks, bytecode, and constants. Priority allocations may use the entire budget.
constexpr std::size_t internal_budget = 256 * 1024;
constexpr std::size_t priority_reserve = 64 * 1024;
constexpr std::size_t psram_threshold = 4 * 1024;

struct Usage {
    std::size_t internal_bytes = 0;
    std::size_t priority_internal_bytes = 0;
};

void* allocate(void* context, void* ptr, std::size_t old_size, std::size_t size);

}
