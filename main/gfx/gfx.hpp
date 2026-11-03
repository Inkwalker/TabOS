#pragma once

#include "M5Unified.h"

namespace gfx {

constexpr int screen_width = 1280;
constexpr int screen_height = 720;
constexpr int scale = 4;
static_assert(screen_width % scale == 0 && screen_height % scale == 0);

constexpr int canvas_width = screen_width / scale;
constexpr int canvas_height = screen_height / scale;

// Call after M5.begin().
bool init();

// Returns nullptr before successful initialization.
M5Canvas* active_canvas();

// Block untill prevoius swap is completed
bool swap_canvas();
void set_color(uint16_t color);
uint16_t get_color();

}
