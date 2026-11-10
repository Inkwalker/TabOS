#pragma once

#include "M5Unified.h"
#include "LGFX_PPA.hpp"

namespace lua_vm {
class Module;
}

namespace gfx {

constexpr int screen_width = 1280;
constexpr int screen_height = 720;
constexpr int scale = 4;
static_assert(screen_width % scale == 0 && screen_height % scale == 0);

constexpr int canvas_width = screen_width / scale;
constexpr int canvas_height = screen_height / scale;

// Call after M5.begin(), on the same core.
bool init();

lua_vm::Module lua_module();

// Returns nullptr before successful initialization.
lgfx::PPA_Sprite* active_canvas();

// Publish the drawn canvas, replacing any pending frame.
bool swap_canvas();

// Blocking PPA operations with clipping and software fallback. Drawing pixels
// are ready for reads, subsequent software drawing, and flip() on return.
void fill_rect(int x, int y, int width, int height, uint16_t color);
void draw_sprite(lgfx::PPA_Sprite& sprite, int x, int y, int32_t transparent = -1);

// Last sampled rate of confirmed framebuffer swaps, or zero before the first sample.
float presenter_fps();

void set_color(uint16_t color);
uint16_t get_color();

}
