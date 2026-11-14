#include "lua_memory.hpp"
#include "lua_memory_tags.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <limits>

#if defined(TABOS_LUA_MEMORY_TEST)
#include "../../tools/lua_memory_test_stubs/esp_heap_caps.h"
#include "../../tools/lua_memory_test_stubs/esp_memory_utils.h"
#else
#include "esp_heap_caps.h"
#include "esp_memory_utils.h"
#endif

namespace lua_vm::memory {
namespace {
constexpr uint32_t internal_caps = MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT;
constexpr uint32_t psram_caps = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT;

// Preserve allocation class across growth, shrink, and free. A size heuristic
// cannot distinguish a large stack/code array from a large table or string.
// ESP heaps need not provide max_align_t alignment. Retain the raw allocation
// and align the payload explicitly, including after a realloc changes address.
struct Header {
    void* allocation;
    bool priority;
};
constexpr std::size_t alignment = alignof(std::max_align_t);
constexpr std::size_t overhead = sizeof(Header) + alignment - 1;
}

void* allocate(void* context, void* ptr, std::size_t old_size, std::size_t size)
{
    auto& usage = *static_cast<Usage*>(context);
    auto* old_header = ptr ? static_cast<Header*>(ptr) - 1 : nullptr;
    const bool priority = old_header ? old_header->priority :
        (old_size == TABOS_LUA_ALLOC_STACK || old_size == TABOS_LUA_ALLOC_BYTECODE);
    void* old_allocation = old_header ? old_header->allocation : nullptr;
    const auto old_offset = ptr ? static_cast<char*>(ptr) - static_cast<char*>(old_allocation) : 0;
    const bool was_internal = old_allocation && esp_ptr_internal(old_allocation);
    // For new objects old_size is a type tag, not a byte count.
    const auto old_bytes = old_header ? old_size + overhead : 0;
    const auto other_internal = usage.internal_bytes - (was_internal ? old_bytes : 0);
    const auto other_priority = usage.priority_internal_bytes -
        (was_internal && priority ? old_bytes : 0);
    if (size == 0) {
        heap_caps_free(old_allocation);
        usage.internal_bytes = other_internal;
        usage.priority_internal_bytes = other_priority;
        return nullptr;
    }
    if (size > std::numeric_limits<std::size_t>::max() - overhead) {
        return nullptr;
    }

    const auto bytes = size + overhead;
    const auto reserved = other_priority < priority_reserve ? priority_reserve - other_priority : 0;
    const auto limit = priority ? internal_budget : internal_budget - reserved;
    const bool fits = other_internal <= limit && bytes <= limit - other_internal;
    const bool keep_internal = was_internal && size <= old_size;
    // Priority blocks ignore the large-object threshold and can return from
    // PSRAM when SRAM headroom becomes available. Ordinary PSRAM blocks stay
    // there on growth to avoid copying them back whenever the budget fluctuates.
    const bool prefer_internal = keep_internal || (fits &&
        (priority || ((!ptr || was_internal) && size < psram_threshold)));
    void* result = heap_caps_realloc_prefer(old_allocation, bytes, 2,
        prefer_internal ? internal_caps : psram_caps,
        prefer_internal ? psram_caps : internal_caps);
    if (!result) return nullptr; // Failed realloc preserves block and counters.

    const auto address = (reinterpret_cast<std::uintptr_t>(result) + sizeof(Header) + alignment - 1)
        & ~(static_cast<std::uintptr_t>(alignment) - 1);
    auto* payload = reinterpret_cast<char*>(address);
    if (old_bytes != 0 && payload != static_cast<char*>(result) + old_offset) {
        // Realloc preserves bytes at the old offset; realign the user data
        // before writing the new header, which may overlap that old data.
        std::memmove(payload, static_cast<char*>(result) + old_offset, std::min(old_size, size));
    }
    auto* header = reinterpret_cast<Header*>(payload) - 1;
    header->allocation = result;
    header->priority = priority;
    const bool is_internal = esp_ptr_internal(result);
    usage.internal_bytes = other_internal + (is_internal ? bytes : 0);
    usage.priority_internal_bytes = other_priority + (is_internal && priority ? bytes : 0);
    return payload;
}
}
