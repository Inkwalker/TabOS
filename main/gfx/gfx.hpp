#pragma once

#include "M5Unified.h"

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
M5Canvas* active_canvas();

// Publish the drawn canvas, replacing any pending frame.
bool swap_canvas();

// Last sampled rate of confirmed framebuffer swaps, or zero before the first sample.
float presenter_fps();

void set_color(uint16_t color);
uint16_t get_color();

}
