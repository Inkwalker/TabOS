#include "gfx.hpp"

#include <atomic>
#include <cstring>
#include <utility>

#include "esp_async_memcpy.h"
#include "esp_cache.h"
#include "esp_ipc.h"
#include "esp_lcd_panel_ops.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "lgfx/v1/platforms/esp32p4/Panel_DSI.hpp"

namespace gfx {

namespace {

constexpr const char* tag = "gfx";
constexpr uint32_t framebuffer_bytes = screen_width * screen_height * sizeof(uint16_t);
std::atomic<float> measured_presenter_fps{0.0f};

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
    esp_lcd_panel_handle_t panel = nullptr;
    uint8_t* framebuffers[2]{};
    int back_index = 1; // The DPI driver starts on framebuffer 0.
    int scanout_core = 0;
};

bool signal_copy_done(async_memcpy_handle_t, async_memcpy_event_t*, void* context)
{
    BaseType_t task_woken = pdFALSE;
    xSemaphoreGiveFromISR(static_cast<SemaphoreHandle_t>(context), &task_woken);
    return task_woken == pdTRUE;
}

// M5GFX exposes the framebuffer pointer but keeps its DPI handle protected.
struct DsiPanelAccess : lgfx::Panel_DSI {
    static esp_lcd_panel_handle_t handle(const lgfx::Panel_DSI& panel)
    {
        return panel.*(&DsiPanelAccess::_disp_panel_handle);
    }
};

StaticSemaphore_t scanout_storage;
SemaphoreHandle_t scanout_done = nullptr;

bool IRAM_ATTR signal_scanout_done(esp_lcd_panel_handle_t, esp_lcd_dpi_panel_event_data_t*, void*)
{
    BaseType_t task_woken = pdFALSE;
    xSemaphoreGiveFromISR(scanout_done, &task_woken);
    return task_woken == pdTRUE;
}

void reset_scanout_events(void*)
{
    xQueueReset(scanout_done);
}

bool init_screen_transfer(ScreenTransfer& transfer)
{
    auto* panel = M5.Display.getPanel();
    if (!panel || !panel->getBus() || panel->getBus()->busType() != lgfx::bus_type_t::bus_dsi ||
        M5.Display.getColorDepth() != lgfx::color_depth_t::rgb565_nonswapped) {
        return false;
    }

    transfer.panel = DsiPanelAccess::handle(*static_cast<lgfx::Panel_DSI*>(panel));
    void* front = nullptr;
    void* back = nullptr;
    if (esp_lcd_dpi_panel_get_frame_buffer(transfer.panel, 2, &front, &back) != ESP_OK) {
        return false;
    }
    transfer.framebuffers[0] = static_cast<uint8_t*>(front);
    transfer.framebuffers[1] = static_cast<uint8_t*>(back);

    bool dma_aligned = true;
    for (auto* framebuffer : transfer.framebuffers) {
        // Publish and invalidate any cached writes from display initialization.
        if (esp_cache_msync(framebuffer, framebuffer_bytes,
                           ESP_CACHE_MSYNC_FLAG_DIR_C2M | ESP_CACHE_MSYNC_FLAG_INVALIDATE |
                               ESP_CACHE_MSYNC_FLAG_UNALIGNED) != ESP_OK) {
            return false;
        }
        const auto address = reinterpret_cast<uintptr_t>(framebuffer);
        dma_aligned &= address % dma_alignment == 0 && address % dma_burst_bytes == 0;
    }

    if (dma_aligned) {
        transfer.done = xSemaphoreCreateBinary();
        if (transfer.done) {
            async_memcpy_config_t config{};
            config.dma_burst_size = dma_burst_bytes;
            if (esp_async_memcpy_install_gdma_axi(&config, &transfer.dma) != ESP_OK) {
                vSemaphoreDelete(transfer.done);
                transfer.done = nullptr;
            }
        }
    }
    return true;
}

void copy_to_screen(const M5Canvas& canvas, ScreenTransfer& transfer, uint8_t* framebuffer)
{
    static_assert(scale == 4);
    constexpr int row_words = screen_height / 2;
    const auto* pixels = static_cast<const uint16_t*>(canvas.getBuffer());
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
        auto* destination = framebuffer + (band / band_columns) * sizeof(expanded_band);
        if (transfer.dma) {
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
                transfer.dma = nullptr;
                transfer.done = nullptr;
            }
        }
        if (!transfer.dma) {
            std::memcpy(destination, expanded_band, sizeof(expanded_band));
        }
    }
}

void present_framebuffer(ScreenTransfer& transfer, const uint8_t* framebuffer)
{
    // Passing a driver-owned buffer publishes it for the next scanout DMA restart.
    const auto result = esp_lcd_panel_draw_bitmap(transfer.panel, 0, 0,
                                                  screen_height, screen_width, framebuffer);
    if (result != ESP_OK) {
        ESP_LOGE(tag, "Framebuffer submission failed (%s)", esp_err_to_name(result));
        return;
    }

    // An ISR that selected the old buffer must finish before the IPC task can
    // clear events on that core.
    if (esp_ipc_call_blocking(transfer.scanout_core, reset_scanout_events, nullptr) != ESP_OK) {
        // A local reset can race the ISR, so wait through an extra restart.
        reset_scanout_events(nullptr);
        xSemaphoreTake(scanout_done, portMAX_DELAY);
    }
    xSemaphoreTake(scanout_done, portMAX_DELAY);
    transfer.back_index ^= 1;

    const auto now = esp_timer_get_time();
    static int64_t sample_start = now;
    static unsigned presented = 0;
    const auto elapsed = now - sample_start;
    if (elapsed >= 1000000) {
        measured_presenter_fps.store(presented * 1000000.0f / elapsed,
                                     std::memory_order_relaxed);
        sample_start = now;
        presented = 0;
    }
    ++presented;
}

M5Canvas canvases[3];
int active_index = 0;
int mailbox_index = 1;
bool frame_pending = false;
portMUX_TYPE mailbox_lock = portMUX_INITIALIZER_UNLOCKED;
TaskHandle_t presenter = nullptr;
ScreenTransfer transfer;

void present_frames(void*)
{
    int presenter_index = 2;
    for (;;) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        portENTER_CRITICAL(&mailbox_lock);
        const bool has_frame = frame_pending;
        if (has_frame) {
            std::swap(presenter_index, mailbox_index);
            frame_pending = false;
        }
        portEXIT_CRITICAL(&mailbox_lock);
        if (!has_frame) {
            continue;
        }

        auto* framebuffer = transfer.framebuffers[transfer.back_index];
        copy_to_screen(canvases[presenter_index], transfer, framebuffer);
        present_framebuffer(transfer, framebuffer);
    }
}

bool start_presenter()
{
    if (!scanout_done) {
        scanout_done = xSemaphoreCreateCountingStatic(2, 0, &scanout_storage);
    }
    if (scanout_done && init_screen_transfer(transfer)) {
        // M5.begin() installs the scanout DMA interrupt on this core.
        transfer.scanout_core = xPortGetCoreID();
        esp_lcd_dpi_panel_event_callbacks_t callbacks{};
        callbacks.on_frame_buf_complete = signal_scanout_done;
        const auto result = esp_lcd_dpi_panel_register_event_callbacks(transfer.panel, &callbacks,
                                                                      nullptr);
        if (result == ESP_OK &&
            xTaskCreatePinnedToCore(present_frames, "gfx_present", 4096, nullptr,
                                    uxTaskPriorityGet(nullptr), &presenter,
                                    1 - transfer.scanout_core) == pdPASS) {
            ESP_LOGI(tag, "4x integer presentation using %s", transfer.dma ? "AXI DMA" : "CPU");
            return true;
        }
        if (result == ESP_OK) {
            callbacks.on_frame_buf_complete = nullptr;
            esp_lcd_dpi_panel_register_event_callbacks(transfer.panel, &callbacks, nullptr);
        }
    }
    if (transfer.dma) esp_async_memcpy_uninstall(transfer.dma);
    if (transfer.done) vSemaphoreDelete(transfer.done);
    transfer = {};
    return false;
}

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
    if (!setup_canvas(canvases[0]) || !setup_canvas(canvases[1]) ||
        !setup_canvas(canvases[2]) || !start_presenter()) {
        for (auto& canvas : canvases) {
            canvas.deleteSprite();
        }
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

    // Reclaim the mailbox canvas, dropping its frame if it was still pending.
    portENTER_CRITICAL(&mailbox_lock);
    std::swap(active_index, mailbox_index);
    frame_pending = true;
    portEXIT_CRITICAL(&mailbox_lock);
    xTaskNotifyGive(presenter);
    return true;
}

float presenter_fps()
{
    return measured_presenter_fps.load(std::memory_order_relaxed);
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
