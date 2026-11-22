#pragma once

#include "esp_err.h"
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
constexpr size_t target_capacity = 128 * 1024;

// Call after M5.begin(), on the same core.
bool init();

lua_vm::Module lua_module();

// Renderer-only canvas access. Lua bindings enqueue canvas operations.
// Returns nullptr before successful initialization.
lgfx::PPA_Sprite* active_canvas();

// Renderer-only: snapshot the active canvas for the presenter and reset clipping.
esp_err_t swap_canvas();
// Renderer-only: discard pixels, reset clipping and resize the shared SRAM canvas.
esp_err_t select_target(int width, int height);
// Renderer-only: save the active canvas to an equally sized sprite.
esp_err_t save_canvas(lgfx::PPA_Sprite& sprite);

// Renderer-only blocking operations with clipping and software fallback. Drawing pixels
// are ready for reads, subsequent software drawing, and flip() on return.
void fill_rect(int x, int y, int width, int height, uint16_t color);
void fill_triangle(int x0, int y0, int x1, int y1, int x2, int y2, uint16_t color);
void draw_sprite(lgfx::PPA_Sprite& sprite, int x, int y, int32_t transparent = -1,
                 bool flip_x = false, bool flip_y = false);

// CPU-only nearest-neighbor sprite region blit. Out-of-bounds source samples
// are skipped; destination clipping does not change the sampling transform.
void draw_sprite_region(lgfx::PPA_Sprite& sprite, int sx, int sy, int sw, int sh,
                        int dx, int dy, int dw, int dh, int32_t transparent = -1,
                        bool flip_x = false, bool flip_y = false);

// Inclusive textured line, sampled from the first endpoint toward the second.
// Finite source coordinates/steps may be fractional and wrap at sprite bounds.
void draw_textured_line(lgfx::PPA_Sprite& sprite, int x0, int y0, int x1, int y1,
                        float sx, float sy, float sdx, float sdy);
// Three screen (x, y) pairs and the corresponding sprite (u, v) pairs.
void draw_textured_triangle(lgfx::PPA_Sprite& sprite, const int xy[6], const float uv[6]);

// Last sampled rate of confirmed framebuffer swaps, or zero before the first sample.
float presenter_fps();

void set_color(uint16_t color);
uint16_t get_color();

}
