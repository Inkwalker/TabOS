#include "lua_memory.hpp"
#include "lua_memory_tags.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <limits>

#include "esp_heap_caps.h"

namespace lua_vm::memory {
namespace {
constexpr std::size_t sram_pool_size = 128 * 1024;
// DMA capability selects main SRAM and excludes RTC RAM and scratchpad memory.
constexpr uint32_t sram_caps = MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA | MALLOC_CAP_8BIT;
constexpr uint32_t psram_caps = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT;

// Preserve allocation class across growth, shrink, and free. A size heuristic
// cannot distinguish VM stacks, bytecode, or constants from other objects.
// ESP heaps need not provide max_align_t alignment. Retain the raw allocation
// and align the payload explicitly, including after a realloc changes address.
struct Header {
    void* allocation;
    bool priority;
    bool in_sram;
};
constexpr std::size_t alignment = alignof(std::max_align_t);
constexpr std::size_t overhead = sizeof(Header) + alignment - 1;
}

Allocator::Allocator()
{
    sram_buffer_ = heap_caps_malloc(sram_pool_size, sram_caps);
    if (sram_buffer_) {
        sram_heap_ = multi_heap_register(sram_buffer_, sram_pool_size);
        if (!sram_heap_) {
            heap_caps_free(sram_buffer_);
            sram_buffer_ = nullptr;
        }
    }
}

Allocator::~Allocator()
{
    heap_caps_free(sram_buffer_);
}

void Allocator::free(void* ptr, bool in_sram)
{
    if (in_sram) {
        multi_heap_free(sram_heap_, ptr);
    } else {
        heap_caps_free(ptr);
    }
}

void* Allocator::allocate(void* context, void* ptr, std::size_t old_size, std::size_t size)
{
    auto& allocator = *static_cast<Allocator*>(context);
    const auto* old_header = ptr ? static_cast<Header*>(ptr) - 1 : nullptr;
    void* old_allocation = old_header ? old_header->allocation : nullptr;
    const bool was_in_sram = old_header && old_header->in_sram;
    if (size == 0) {
        allocator.free(old_allocation, was_in_sram);
        return nullptr;
    }
    if (size > std::numeric_limits<std::size_t>::max() - overhead) {
        return nullptr;
    }

    // For new objects old_size is a type tag, not a byte count.
    const bool priority = old_header ? old_header->priority :
        (old_size == TABOS_LUA_ALLOC_STACK || old_size == TABOS_LUA_ALLOC_BYTECODE ||
         old_size == TABOS_LUA_ALLOC_CONSTANTS);
    const auto old_offset = ptr ? static_cast<char*>(ptr) - static_cast<char*>(old_allocation) : 0;
    const auto copy_size = ptr ? std::min(old_size, size) : 0;
    const auto bytes = size + overhead;
    void* result = nullptr;
    if (priority && allocator.sram_heap_) {
        result = multi_heap_realloc(allocator.sram_heap_, was_in_sram ? old_allocation : nullptr, bytes);
    }
    const bool in_sram = result != nullptr;
    if (!result) {
        result = heap_caps_realloc(was_in_sram ? nullptr : old_allocation, bytes, psram_caps);
        if (!result) return nullptr; // The old allocation is still valid.
    }

    const auto address = (reinterpret_cast<std::uintptr_t>(result) + sizeof(Header) + alignment - 1)
        & ~(static_cast<std::uintptr_t>(alignment) - 1);
    auto* payload = reinterpret_cast<char*>(address);
    if (copy_size != 0) {
        if (in_sram != was_in_sram) {
            std::memcpy(payload, ptr, copy_size);
            allocator.free(old_allocation, was_in_sram);
        } else if (payload != static_cast<char*>(result) + old_offset) {
            // Realloc preserves bytes at the old offset. Realign before writing the header.
            std::memmove(payload, static_cast<char*>(result) + old_offset, copy_size);
        }
    }
    auto* header = reinterpret_cast<Header*>(payload) - 1;
    header->allocation = result;
    header->priority = priority;
    header->in_sram = in_sram;
    return payload;
}
}
