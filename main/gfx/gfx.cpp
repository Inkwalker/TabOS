#include "gfx.hpp"

#include <cstring>

#include "esp_async_memcpy.h"
#include "esp_cache.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "lgfx/v1/platforms/esp32p4/Panel_DSI.hpp"

namespace gfx {

namespace {

constexpr const char* tag = "gfx";
constexpr uint32_t framebuffer_bytes = screen_width * screen_height * sizeof(uint16_t);

constexpr int band_columns = 4;
constexpr int dma_burst_bytes = 64;
constexpr int dma_alignment = CONFIG_CACHE_L2_CACHE_LINE_SIZE;
static_assert(canvas_width % band_columns == 0);
// A band of native portrait rows, kept in internal RAM and off the task stack.
alignas(128) uint32_t expanded_band[band_columns * scale * screen_height / 2];
static_assert(sizeof(expanded_band) % 128 == 0);

struct ScreenTransfer {
    async_memcpy_handle_t dma = nullptr;
    SemaphoreHandle_t done = nullptr;
    uint8_t* framebuffer = nullptr;
};

bool signal_copy_done(async_memcpy_handle_t, async_memcpy_event_t*, void* context)
{
    BaseType_t task_woken = pdFALSE;
    xSemaphoreGiveFromISR(static_cast<SemaphoreHandle_t>(context), &task_woken);
    return task_woken == pdTRUE;
}

uint8_t* prepare_framebuffer()
{
    auto* panel = M5.Display.getPanel();
    if (!panel || !panel->getBus() || panel->getBus()->busType() != lgfx::bus_type_t::bus_dsi ||
        M5.Display.getColorDepth() != lgfx::color_depth_t::rgb565_nonswapped) {
        return {};
    }
    // All three Tab5 panels in the pinned M5GFX use this DSI framebuffer.
    auto* framebuffer = static_cast<uint8_t*>(
        static_cast<lgfx::Panel_DSI*>(panel)->config_detail().buffer);
    if (!framebuffer || reinterpret_cast<uintptr_t>(framebuffer) % dma_alignment != 0 ||
        reinterpret_cast<uintptr_t>(framebuffer) % dma_burst_bytes != 0) {
        return {};
    }
    // Finish any cached CPU writes from display initialization before DMA owns it.
    if (esp_cache_msync(framebuffer, framebuffer_bytes,
                       ESP_CACHE_MSYNC_FLAG_DIR_C2M | ESP_CACHE_MSYNC_FLAG_INVALIDATE) != ESP_OK) {
        return {};
    }
    return framebuffer;
}

ScreenTransfer init_screen_transfer()
{
    auto* framebuffer = prepare_framebuffer();
    if (!framebuffer) {
        return {};
    }
    auto done = xSemaphoreCreateBinary();
    if (!done) {
        return {};
    }
    async_memcpy_handle_t dma = nullptr;
    async_memcpy_config_t config{};
    config.dma_burst_size = dma_burst_bytes;
    if (esp_async_memcpy_install_gdma_axi(&config, &dma) != ESP_OK) {
        vSemaphoreDelete(done);
        return {};
    }
    return {dma, done, framebuffer};
}

void copy_to_screen(const M5Canvas& canvas, ScreenTransfer& transfer)
{
    static_assert(scale == 4);
    constexpr int row_words = screen_height / 2;
    const auto* pixels = static_cast<const uint16_t*>(canvas.getBuffer());
    M5.Display.startWrite();
    for (int band = 0; band < canvas_width; band += band_columns) {
        for (int y = 0; y < canvas_height; ++y) {
            const auto* source = pixels + y * canvas_width + canvas_width - 1 - band;
            for (int column = 0; column < band_columns; ++column) {
                // Landscape rotation 3 maps (x, y) to (y, width - 1 - x).
                const uint32_t pixel = source[-column];
                const uint32_t pair = pixel | (pixel << 16);
                auto* row = expanded_band + column * scale * row_words;
                row[y * 2] = pair;
                row[y * 2 + 1] = pair;
            }
        }
        for (int column = 0; column < band_columns; ++column) {
            auto* row = expanded_band + column * scale * row_words;
            for (int duplicate = 1; duplicate < scale; ++duplicate) {
                std::memcpy(row + duplicate * row_words, row, row_words * sizeof(*row));
            }
        }
        if (transfer.dma) {
            auto* destination = transfer.framebuffer + (band / band_columns) * sizeof(expanded_band);
            const esp_err_t result = esp_async_memcpy(transfer.dma, destination, expanded_band,
                                                       sizeof(expanded_band), signal_copy_done,
                                                       transfer.done);
            if (result == ESP_OK) {
                // The staging band can be reused after the DMA completion interrupt.
                xSemaphoreTake(transfer.done, portMAX_DELAY);
            } else {
                ESP_LOGW(tag, "DMA submission failed (%s); using CPU copy", esp_err_to_name(result));
                esp_async_memcpy_uninstall(transfer.dma);
                vSemaphoreDelete(transfer.done);
                transfer = {};
            }
        }
        if (!transfer.dma) {
            M5.Display.pushImage(0, band * scale, screen_height, band_columns * scale,
                                 static_cast<const void*>(expanded_band),
                                 lgfx::color_depth_t::rgb565_nonswapped,
                                 static_cast<const lgfx::bgr888_t*>(nullptr));
        }
    }
    // endWrite also publishes modified framebuffer cache lines on this driver.
    // Scanout runs independently; this does not wait for vsync.
    M5.Display.endWrite();
}

QueueHandle_t frames = nullptr;
SemaphoreHandle_t idle = nullptr;
ScreenTransfer transfer;

void present_frames(void*)
{
    for (;;) {
        const M5Canvas* frame = nullptr;
        xQueueReceive(frames, &frame, portMAX_DELAY);
        copy_to_screen(*frame, transfer);
        xSemaphoreGive(idle);
    }
}

bool start_presenter()
{
    frames = xQueueCreate(1, sizeof(const M5Canvas*));
    idle = xSemaphoreCreateBinary();
    if (frames && idle) {
        transfer = init_screen_transfer();
        xSemaphoreGive(idle);
        if (xTaskCreatePinnedToCore(present_frames, "gfx_present", 4096, nullptr,
                                    uxTaskPriorityGet(nullptr), nullptr,
                                    1 - xPortGetCoreID()) == pdPASS) {
            ESP_LOGI(tag, "4x integer presentation using %s", transfer.dma ? "AXI DMA" : "CPU");
            return true;
        }
        if (transfer.dma) esp_async_memcpy_uninstall(transfer.dma);
        if (transfer.done) vSemaphoreDelete(transfer.done);
        transfer = {};
    }
    if (frames) vQueueDelete(frames);
    if (idle) vSemaphoreDelete(idle);
    frames = nullptr;
    idle = nullptr;
    return false;
}

M5Canvas canvases[2];
int active_index = 0;
bool initialized = false;
uint16_t draw_color = TFT_WHITE;

bool setup_canvas(M5Canvas& canvas)
{
    canvas.setColorDepth(lgfx::color_depth_t::rgb565_nonswapped);
    canvas.setPsram(true);
    if (!canvas.createSprite(canvas_width, canvas_height)) {
        return false;
    }
    canvas.setTextSize(1);
    canvas.setTextColor(TFT_WHITE, TFT_BLACK);
    canvas.setTextWrap(false);
    return true;
}

}

bool init()
{
    if (initialized) {
        return true;
    }
    if (M5.getBoard() != m5::board_t::board_M5Tab5 || !M5.Display.getPanel()) {
        ESP_LOGE(tag, "Initialize the Tab5 display before gfx");
        return false;
    }
    M5.Display.setRotation(0);
    if (M5.Display.width() != screen_height || M5.Display.height() != screen_width) {
        ESP_LOGE(tag, "Expected a %dx%d portrait framebuffer", screen_height, screen_width);
        return false;
    }
    if (!setup_canvas(canvases[0]) || !setup_canvas(canvases[1]) || !start_presenter()) {
        canvases[0].deleteSprite();
        canvases[1].deleteSprite();
        return false;
    }
    initialized = true;
    return true;
}

M5Canvas* active_canvas()
{
    return initialized ? &canvases[active_index] : nullptr;
}

bool swap_canvas()
{
    if (!initialized) {
        return false;
    }

    // The other buffer can become writable only after its copy completes.
    xSemaphoreTake(idle, portMAX_DELAY);
    const M5Canvas* completed = &canvases[active_index];
    active_index = 1 - active_index;
    xQueueSend(frames, &completed, portMAX_DELAY);
    return true;
}

void set_color(uint16_t color)
{
    draw_color = color;
}

uint16_t get_color()
{
    return draw_color;
}

}
