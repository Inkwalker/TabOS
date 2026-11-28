#pragma once

#include "gfx.hpp"

namespace gfx {

enum class DrawOp {
    barrier, flip, target, save, pget, clip, reset_clip, clear, set_fill_pattern,
    pixel, circle, fill_circle, ellipse, fill_ellipse, rect, fill_rect, line, fill_triangle,
    sprite, sprite_region, textured_line, textured_triangle, set_font, release_font, text, text_continue,
};

struct CommandCompletion;

// Lua keeps sprite and font storage alive until the renderer has finished using it.
// Text bytes are owned by the queue.
struct DrawCommand {
    DrawOp op;
    int args[8]{};
    uint16_t color = 0;
    int32_t transparent = -1;
    bool flip_x = false;
    bool flip_y = false;
    lgfx::PPA_Sprite* sprite = nullptr;
    CommandCompletion* completion = nullptr;
    union Payload {
        float uv[6]{};
        char text[64];
        const lgfx::GFXfont* font;
    } payload{};
};

bool start_commands();
void stop_commands();
// Single producer: the Lua VM on core 1. A full buffer applies backpressure.
void enqueue(const DrawCommand& command);
esp_err_t execute_and_wait(DrawCommand command, uint16_t* pixel = nullptr);
void wait_commands();

} // namespace gfx
