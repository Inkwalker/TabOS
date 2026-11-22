#include "commands.hpp"

#include <algorithm>
#include <cstdlib>
#include <type_traits>

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

namespace gfx {

struct CommandCompletion {
    StaticSemaphore_t storage;
    SemaphoreHandle_t done;
    esp_err_t result = ESP_OK;
    uint16_t pixel = 0;

    CommandCompletion() : done(xSemaphoreCreateBinaryStatic(&storage)) {}
    ~CommandCompletion() { vSemaphoreDelete(done); }
};

namespace {
QueueHandle_t commands = nullptr;
TaskHandle_t worker = nullptr;
constexpr size_t command_capacity = 128;
static_assert(std::is_trivially_copyable<DrawCommand>::value);

void draw_commands(void*)
{
    DrawCommand command{};
    for (;;) {
        xQueueReceive(commands, &command, portMAX_DELAY);
        auto& target = *active_canvas();
        const auto* a = command.args;
        esp_err_t result = ESP_OK;
        uint16_t pixel = 0;
        switch (command.op) {
        case DrawOp::barrier: break;
        case DrawOp::flip: result = swap_canvas(); break;
        case DrawOp::target: result = select_target(a[0], a[1]); break;
        case DrawOp::save: result = save_canvas(*command.sprite); break;
        case DrawOp::pget: pixel = target.readPixel(a[0], a[1]); break;
        case DrawOp::clip: target.setClipRect(a[0], a[1], a[2], a[3]); break;
        case DrawOp::reset_clip: target.clearClipRect(); break;
        case DrawOp::pixel: target.drawPixel(a[0], a[1], command.color); break;
        case DrawOp::circle: target.drawCircle(a[0], a[1], a[2], command.color); break;
        case DrawOp::fill_circle: target.fillCircle(a[0], a[1], a[2], command.color); break;
        case DrawOp::ellipse: target.drawEllipse(a[0], a[1], a[2], a[3], command.color); break;
        case DrawOp::fill_ellipse: target.fillEllipse(a[0], a[1], a[2], a[3], command.color); break;
        case DrawOp::rect: target.drawRect(a[0], a[1], a[2], a[3], command.color); break;
        case DrawOp::fill_rect: fill_rect(a[0], a[1], a[2], a[3], command.color); break;
        case DrawOp::line:
            if (a[1] == a[3]) {
                target.drawFastHLine(std::min(a[0], a[2]), a[1], std::abs(a[2] - a[0]) + 1, command.color);
            } else if (a[0] == a[2]) {
                target.drawFastVLine(a[0], std::min(a[1], a[3]), std::abs(a[3] - a[1]) + 1, command.color);
            } else {
                target.drawLine(a[0], a[1], a[2], a[3], command.color);
            }
            break;
        case DrawOp::fill_triangle:
            fill_triangle(a[0], a[1], a[2], a[3], a[4], a[5], command.color);
            break;
        case DrawOp::sprite:
            draw_sprite(*command.sprite, a[0], a[1], command.transparent, command.flip_x, command.flip_y);
            break;
        case DrawOp::sprite_region:
            draw_sprite_region(*command.sprite, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7],
                               command.transparent, command.flip_x, command.flip_y);
            break;
        case DrawOp::textured_line:
            draw_textured_line(*command.sprite, a[0], a[1], a[2], a[3],
                               command.payload.uv[0], command.payload.uv[1], command.payload.uv[2], command.payload.uv[3]);
            break;
        case DrawOp::textured_triangle:
            draw_textured_triangle(*command.sprite, a, command.payload.uv);
            break;
        case DrawOp::text:
            target.setTextColor(command.color);
            target.setCursor(a[0], a[1]);
            [[fallthrough]];
        case DrawOp::text_continue:
            target.write(reinterpret_cast<const uint8_t*>(command.payload.text), a[2]);
            break;
        }
        // Receiving the last entry is not completion: acknowledge only after
        // rasterization/PPA/DMA has returned, including for barriers.
        if (command.completion) {
            command.completion->result = result;
            command.completion->pixel = pixel;
            xSemaphoreGive(command.completion->done);
        }
    }
}
} // namespace

bool start_commands()
{
    commands = xQueueCreate(command_capacity, sizeof(DrawCommand));
    if (!commands) return false;
    if (xTaskCreatePinnedToCore(draw_commands, "gfx_draw", 8192, nullptr,
                                uxTaskPriorityGet(nullptr), &worker, 0) != pdPASS) {
        stop_commands();
        return false;
    }
    return true;
}

void stop_commands()
{
    if (worker) vTaskDelete(worker);
    worker = nullptr;
    if (commands) vQueueDelete(commands);
    commands = nullptr;
}

void enqueue(const DrawCommand& command)
{
    configASSERT(commands);
    xQueueSend(commands, &command, portMAX_DELAY);
}

esp_err_t execute_and_wait(DrawCommand command, uint16_t* pixel)
{
    CommandCompletion completion;
    command.completion = &completion;
    enqueue(command);
    xSemaphoreTake(completion.done, portMAX_DELAY);
    if (pixel) *pixel = completion.pixel;
    return completion.result;
}

void wait_commands()
{
    execute_and_wait(DrawCommand{DrawOp::barrier});
}

} // namespace gfx
