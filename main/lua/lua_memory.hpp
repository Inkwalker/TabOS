#pragma once

#include <cstddef>

#include "multi_heap.h"

namespace lua_vm::memory {

class Allocator {
public:
    Allocator();
    ~Allocator();
    Allocator(const Allocator&) = delete;
    Allocator& operator=(const Allocator&) = delete;

    bool has_sram() const { return sram_heap_ != nullptr; }
    static void* allocate(void* context, void* ptr, std::size_t old_size, std::size_t size);

private:
    void free(void* ptr, bool in_sram);

    void* sram_buffer_ = nullptr;
    multi_heap_handle_t sram_heap_ = nullptr;
};

}
