#pragma once

#include "gfx.hpp"

namespace gfx {

enum class DrawOp {
    barrier, flip, pget, clip, reset_clip, pixel, circle, fill_circle,
    ellipse, fill_ellipse, rect, fill_rect, line, sprite, sprite_region,
    textured_line, text, text_continue,
};

struct CommandCompletion;

// Value-only queue entries, except sprite storage which is protected by
// wait_commands() before Lua releases it. Text bytes are owned by the queue.
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
        double source[4]{};
        char text[64];
    } payload{};
};

bool start_commands();
void stop_commands();
// Single producer: the Lua VM on core 1. A full buffer applies backpressure.
void enqueue(const DrawCommand& command);
esp_err_t execute_and_wait(DrawCommand command, uint16_t* pixel = nullptr);
void wait_commands();

} // namespace gfx
