#include "gfx.hpp"
#include "commands.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <utility>

#include "esp_cache.h"
#include "esp_check.h"
#include "esp_ipc.h"
#include "esp_heap_caps.h"
#include "esp_lcd_panel_ops.h"
#include "esp_log.h"
#include "esp_private/esp_dma_utils.h"
#include "esp_private/esp_psram_mspi.h"
#include "esp_private/gdma.h"
#include "esp_private/gdma_link.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "lgfx/v1/platforms/esp32p4/Panel_DSI.hpp"

namespace gfx {

namespace {

constexpr const char* tag = "gfx";
constexpr int ppa_sprite_min_pixels = 64 * 64;
constexpr uint32_t framebuffer_bytes = screen_width * screen_height * sizeof(uint16_t);
std::atomic<float> measured_presenter_fps{0.0f};

constexpr int band_columns = 16;
constexpr int row_bytes = screen_height * sizeof(uint16_t);
constexpr int band_rows = band_columns * scale;
constexpr int band_bytes = band_rows * row_bytes;
constexpr int tx_burst_bytes = 32; // Divides the unpadded row length.
constexpr int rx_burst_bytes = 64;
constexpr int dma_alignment = CONFIG_CACHE_L2_CACHE_LINE_SIZE > rx_burst_bytes
                                  ? CONFIG_CACHE_L2_CACHE_LINE_SIZE : rx_burst_bytes;
constexpr int descriptor_max_bytes = 4095;
constexpr int copy_timeout_ms = 100;
static_assert(scale == 4);
static_assert(canvas_width % band_columns == 0);
static_assert(row_bytes % tx_burst_bytes == 0 && band_bytes % dma_alignment == 0);

// Padding keeps each row cache aligned. DMA reads only the pixel data.
struct alignas(dma_alignment) ExpandedRow {
    uint32_t pixels[screen_height / 2];
};
using ExpandedBand = ExpandedRow[band_columns];
ExpandedBand staging;

class CopyDma {
public:
    CopyDma() = default;
    ~CopyDma() { release(); }
    CopyDma(const CopyDma&) = delete;
    CopyDma& operator=(const CopyDma&) = delete;

    esp_err_t init_bands();
    esp_err_t init_canvas(void* source, size_t size);
    void release();
    bool available() const { return ready_; }
    esp_err_t copy(void* destination);

private:
    esp_err_t configure(size_t source_items, size_t size, size_t tx_burst);
    esp_err_t mount_source(int item, void* source, size_t size, size_t alignment, bool last);
    esp_err_t finish_init(esp_err_t result);

    gdma_channel_handle_t tx_ = nullptr;
    gdma_channel_handle_t rx_ = nullptr;
    gdma_link_list_handle_t source_list_ = nullptr;
    gdma_link_list_handle_t destination_list_ = nullptr;
    SemaphoreHandle_t done_ = nullptr;
    size_t size_ = 0;
    bool tx_connected_ = false;
    bool rx_connected_ = false;
    bool active_ = false;
    bool ready_ = false;
};

struct ScreenTransfer {
    CopyDma copy_dma;
    esp_lcd_panel_handle_t panel = nullptr;
    uint8_t* framebuffers[2]{};
    int back_index = 1; // The DPI driver starts on framebuffer 0.
    int scanout_core = 0;
};

bool IRAM_ATTR signal_copy_done(gdma_channel_handle_t, gdma_event_data_t*, void* context)
{
    BaseType_t task_woken = pdFALSE;
    xSemaphoreGiveFromISR(static_cast<SemaphoreHandle_t>(context), &task_woken);
    return task_woken == pdTRUE;
}

void CopyDma::release()
{
    ready_ = false;
    if (active_) {
        gdma_stop(tx_);
        gdma_stop(rx_);
        gdma_reset(tx_);
        gdma_reset(rx_);
        esp_psram_mspi_mb();
        active_ = false;
    }
    if (tx_) {
        if (tx_connected_) gdma_disconnect(tx_);
        tx_connected_ = false;
        gdma_del_channel(tx_);
        tx_ = nullptr;
    }
    if (rx_) {
        if (rx_connected_) gdma_disconnect(rx_);
        rx_connected_ = false;
        gdma_del_channel(rx_);
        rx_ = nullptr;
    }
    if (source_list_) {
        gdma_del_link_list(source_list_);
        source_list_ = nullptr;
    }
    if (destination_list_) {
        gdma_del_link_list(destination_list_);
        destination_list_ = nullptr;
    }
    if (done_) {
        vSemaphoreDelete(done_);
        done_ = nullptr;
    }
}

esp_err_t CopyDma::finish_init(esp_err_t result)
{
    ready_ = result == ESP_OK;
    if (!ready_) release();
    return result;
}

esp_err_t CopyDma::init_bands()
{
    auto result = configure(band_rows, band_bytes, tx_burst_bytes);
    for (int row = 0; row < band_rows && result == ESP_OK; ++row) {
        result = mount_source(row, staging[row / scale].pixels, row_bytes, tx_burst_bytes,
                              row == band_rows - 1);
    }
    return finish_init(result);
}

esp_err_t CopyDma::init_canvas(void* source, size_t size)
{
    const auto items = esp_dma_calculate_node_count(size, dma_alignment, descriptor_max_bytes);
    auto result = configure(items, size, dma_alignment);
    if (result == ESP_OK) result = mount_source(0, source, size, dma_alignment, true);
    return finish_init(result);
}

esp_err_t CopyDma::mount_source(int item, void* source, size_t size, size_t alignment, bool last)
{
    gdma_buffer_mount_config_t config{};
    config.buffer = source;
    config.buffer_alignment = alignment;
    config.length = size;
    if (last) {
        config.flags.mark_eof = true;
        config.flags.mark_final = GDMA_FINAL_LINK_TO_NULL;
    }
    return gdma_link_mount_buffers(source_list_, item, &config, 1, nullptr);
}

esp_err_t CopyDma::configure(size_t source_items, size_t size, size_t tx_burst)
{
    gdma_channel_alloc_config_t tx_config{};
    tx_config.direction = GDMA_CHANNEL_DIRECTION_TX;
    tx_config.flags.reserve_sibling = true;
    ESP_RETURN_ON_ERROR(gdma_new_axi_channel(&tx_config, &tx_), tag, "allocate copy TX");

    gdma_channel_alloc_config_t rx_config{};
    rx_config.direction = GDMA_CHANNEL_DIRECTION_RX;
    rx_config.sibling_chan = tx_;
    ESP_RETURN_ON_ERROR(gdma_new_axi_channel(&rx_config, &rx_), tag, "allocate copy RX");

    uint32_t free_triggers = 0;
    ESP_RETURN_ON_ERROR(gdma_get_free_m2m_trig_id_mask(tx_, &free_triggers),
                        tag, "find copy trigger");
    if (!free_triggers) return ESP_ERR_NOT_FOUND;
    gdma_trigger_t trigger = GDMA_MAKE_TRIGGER(GDMA_TRIG_PERIPH_M2M, 0);
    trigger.instance_id = __builtin_ctz(free_triggers);
    ESP_RETURN_ON_ERROR(gdma_connect(rx_, trigger), tag, "connect copy RX");
    rx_connected_ = true;
    ESP_RETURN_ON_ERROR(gdma_connect(tx_, trigger), tag, "connect copy TX");
    tx_connected_ = true;

    gdma_strategy_config_t strategy{};
    strategy.owner_check = true;
    strategy.eof_till_data_popped = true;
    // TX does not write back descriptor ownership, so its fixed lists can be reused.
    ESP_RETURN_ON_ERROR(gdma_apply_strategy(tx_, &strategy), tag, "configure TX strategy");
    ESP_RETURN_ON_ERROR(gdma_apply_strategy(rx_, &strategy), tag, "configure RX strategy");

    gdma_transfer_config_t config{};
    config.max_data_burst_size = tx_burst;
    ESP_RETURN_ON_ERROR(gdma_config_transfer(tx_, &config), tag, "configure TX burst");
    config.max_data_burst_size = rx_burst_bytes;
    config.access_ext_mem = true;
    ESP_RETURN_ON_ERROR(gdma_config_transfer(rx_, &config), tag, "configure RX burst");

    gdma_link_list_config_t list_config{};
    list_config.item_alignment = 8; // Required by AXI GDMA.
    list_config.num_items = source_items;
    ESP_RETURN_ON_ERROR(gdma_new_link_list(&list_config, &source_list_),
                        tag, "allocate TX descriptors");
    // RX writes back descriptor state. Remount the destination for each copy.
    list_config.num_items = esp_dma_calculate_node_count(size, dma_alignment, descriptor_max_bytes);
    ESP_RETURN_ON_ERROR(gdma_new_link_list(&list_config, &destination_list_),
                        tag, "allocate RX descriptors");
    done_ = xSemaphoreCreateBinary();
    if (!done_) return ESP_ERR_NO_MEM;
    size_ = size;
    gdma_rx_event_callbacks_t callbacks{};
    callbacks.on_recv_eof = signal_copy_done;
    return gdma_register_rx_event_callbacks(rx_, &callbacks, done_);
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
        dma_aligned &= address % dma_alignment == 0;
    }

    const auto result = dma_aligned ? transfer.copy_dma.init_bands() : ESP_ERR_INVALID_ARG;
    if (result != ESP_OK) {
        ESP_LOGW(tag, "Copy DMA unavailable (%s); using CPU copy", esp_err_to_name(result));
    }
    return true;
}

void expand_band(const uint16_t* pixels, int band, ExpandedBand& expanded)
{
    for (int y = 0; y < canvas_height; ++y) {
        const auto* source = pixels + y * canvas_width + canvas_width - 1 - band;
        for (int column = 0; column < band_columns; ++column) {
            // Landscape rotation 3 maps (x, y) to (y, width - 1 - x).
            const uint32_t pixel = source[-column];
            const uint32_t pair = pixel | (pixel << 16);
            expanded[column].pixels[y * 2] = pair;
            expanded[column].pixels[y * 2 + 1] = pair;
        }
    }
}

esp_err_t CopyDma::copy(void* destination)
{
    if (!ready_) return ESP_ERR_INVALID_STATE;
    gdma_buffer_mount_config_t target{};
    target.buffer = destination;
    target.buffer_alignment = dma_alignment;
    target.length = size_;
    target.flags.mark_final = GDMA_FINAL_LINK_TO_NULL;
    ESP_RETURN_ON_ERROR(gdma_link_mount_buffers(destination_list_, 0, &target, 1, nullptr),
                        tag, "mount RX destination");
    ESP_RETURN_ON_ERROR(gdma_start(rx_, gdma_link_get_head_addr(destination_list_)),
                        tag, "start copy RX");
    active_ = true;
    ESP_RETURN_ON_ERROR(gdma_start(tx_, gdma_link_get_head_addr(source_list_)),
                        tag, "start copy TX");
    // Wait until DMA has finished reading the source before returning it to the caller.
    if (xSemaphoreTake(done_, pdMS_TO_TICKS(copy_timeout_ms)) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }
    active_ = false;
    return ESP_OK;
}

esp_err_t copy_frame_dma(const uint16_t* pixels, CopyDma& dma, uint8_t* framebuffer)
{
    for (int band = 0; band < canvas_width; band += band_columns) {
        expand_band(pixels, band, staging);
        ESP_RETURN_ON_ERROR(esp_cache_msync(staging, sizeof(staging), ESP_CACHE_MSYNC_FLAG_DIR_C2M),
                            tag, "publish staging pixels");
        auto* destination = framebuffer + (band / band_columns) * band_bytes;
        const auto result = dma.copy(destination);
        if (result != ESP_OK) return result;
    }
    return ESP_OK;
}

esp_err_t copy_to_screen(const lgfx::PPA_Sprite& canvas, ScreenTransfer& transfer,
                          uint8_t* framebuffer)
{
    const auto* pixels = static_cast<const uint16_t*>(canvas.getBuffer());
    if (transfer.copy_dma.available()) {
        const auto result = copy_frame_dma(pixels, transfer.copy_dma, framebuffer);
        if (result == ESP_OK) {
            // Match the IDF async-copy driver's PSRAM barrier before publishing DMA writes.
            esp_psram_mspi_mb();
            return ESP_OK;
        }

        ESP_LOGW(tag, "Copy DMA failed (%s); using CPU copy", esp_err_to_name(result));
        transfer.copy_dma.release();
    }

    auto* destination = framebuffer;
    for (int band = 0; band < canvas_width; band += band_columns) {
        expand_band(pixels, band, staging);
        for (const auto& row : staging) {
            for (int duplicate = 0; duplicate < scale; ++duplicate) {
                std::memcpy(destination, row.pixels, row_bytes);
                destination += row_bytes;
            }
        }
    }
    return esp_cache_msync(framebuffer, framebuffer_bytes, ESP_CACHE_MSYNC_FLAG_DIR_C2M);
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

constexpr size_t canvas_bytes = canvas_width * canvas_height * sizeof(uint16_t);
static_assert(canvas_bytes % dma_alignment == 0);
lgfx::PPA_Sprite drawing_canvas;
lgfx::PPA_Sprite canvases[2];
std::unique_ptr<lgfx::PPABlend> ppa_blend;
CopyDma submit_dma;
int mailbox_index = 1;
bool frame_pending = false;
portMUX_TYPE mailbox_lock = portMUX_INITIALIZER_UNLOCKED;
TaskHandle_t presenter = nullptr;
ScreenTransfer transfer;

void present_frames(void*)
{
    int presenter_index = 0;
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
        const auto result = copy_to_screen(canvases[presenter_index], transfer, framebuffer);
        if (result != ESP_OK) {
            ESP_LOGE(tag, "Framebuffer copy failed (%s)", esp_err_to_name(result));
            continue;
        }
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
            ESP_LOGI(tag, "4x integer presentation using %s",
                     transfer.copy_dma.available() ? "AXI DMA (single staging buffer)" : "CPU");
            return true;
        }
        if (result == ESP_OK) {
            callbacks.on_frame_buf_complete = nullptr;
            esp_lcd_dpi_panel_register_event_callbacks(transfer.panel, &callbacks, nullptr);
        }
    }
    transfer.copy_dma.release();
    return false;
}

bool initialized = false;
uint16_t draw_color = TFT_WHITE;

bool setup_canvas(lgfx::PPA_Sprite& canvas, uint32_t caps, size_t bytes = canvas_bytes)
{
    auto* pixels = heap_caps_aligned_calloc(dma_alignment, 1, bytes, caps);
    if (!pixels) {
        ESP_LOGE(tag, "Could not allocate canvas pixels (caps %#lx)",
                 static_cast<unsigned long>(caps));
        return false;
    }
    canvas.setColorDepth(lgfx::color_depth_t::rgb565_nonswapped);
    canvas.setBuffer(pixels, canvas_width, canvas_height);
    canvas.setTextSize(1);
    canvas.setTextColor(TFT_WHITE);
    canvas.setTextWrap(false);
    return true;
}

void release_canvas(lgfx::PPA_Sprite& canvas)
{
    auto* pixels = canvas.getBuffer();
    canvas.deleteSprite();
    heap_caps_free(pixels);
}

bool init_submit_dma()
{
    // Keep the descriptor lists for the lifetime of the canvas, including across flips.
    const auto result = submit_dma.init_canvas(drawing_canvas.getBuffer(), canvas_bytes);
    if (result != ESP_OK) {
        ESP_LOGE(tag, "Could not initialize canvas DMA (%s)", esp_err_to_name(result));
    }
    return result == ESP_OK;
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
    if (!setup_canvas(drawing_canvas, MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA | MALLOC_CAP_8BIT,
                      target_capacity) ||
        !setup_canvas(canvases[0], MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT) ||
        !setup_canvas(canvases[1], MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT) ||
        !init_submit_dma() ||
        !start_commands() ||
        !start_presenter()) {
        stop_commands();
        submit_dma.release();
        release_canvas(drawing_canvas);
        for (auto& canvas : canvases) {
            release_canvas(canvas);
        }
        return false;
    }
    // Use blocking sprite blits so CPU rasterization and pixel reads can safely
    // interleave with PPA writes. The presenter only reads snapshot buffers.
    ppa_blend.reset(new (std::nothrow) lgfx::PPABlend(&drawing_canvas, false));
    if (ppa_blend && !ppa_blend->available()) ppa_blend.reset();
    ESP_LOGI(tag, "Drawing: CPU fills, %s sprite blits", ppa_blend ? "CPU/PPA" : "CPU");
    initialized = true;
    return true;
}

lgfx::PPA_Sprite* active_canvas()
{
    return initialized ? &drawing_canvas : nullptr;
}

esp_err_t select_target(int width, int height)
{
    if (!initialized) return ESP_ERR_INVALID_STATE;
    if (width <= 0 || height <= 0 || width > INT16_MAX || height > INT16_MAX
        || size_t(width) * height * sizeof(uint16_t) > target_capacity) {
        return ESP_ERR_INVALID_ARG;
    }
    auto* pixels = drawing_canvas.getBuffer();
    drawing_canvas.setBuffer(pixels, width, height);
    drawing_canvas.clearClipRect();
    drawing_canvas.setCursor(0, 0);
    drawing_canvas.fillScreen(uint16_t(0));
    return ESP_OK;
}

esp_err_t save_canvas(lgfx::PPA_Sprite& sprite)
{
    if (sprite.width() != drawing_canvas.width() || sprite.height() != drawing_canvas.height()) {
        return ESP_ERR_INVALID_ARG;
    }
    std::memcpy(sprite.getBuffer(), drawing_canvas.getBuffer(),
                size_t(sprite.width()) * sprite.height() * sizeof(uint16_t));
    drawing_canvas.clearClipRect();
    return ESP_OK;
}

esp_err_t swap_canvas()
{
    if (!initialized) {
        return ESP_ERR_INVALID_STATE;
    }

    // Every mailbox is a complete 320x180 image. Smaller targets leave black
    // padding, and oversized targets are clipped before presentation.
    const int width = std::min(canvas_width, int(drawing_canvas.width()));
    const int height = std::min(canvas_height, int(drawing_canvas.height()));
    portENTER_CRITICAL(&mailbox_lock);
    frame_pending = false;
    auto* destination = canvases[mailbox_index].getBuffer();
    portEXIT_CRITICAL(&mailbox_lock);

    if (drawing_canvas.width() == canvas_width && height == canvas_height) {
        ESP_RETURN_ON_ERROR(esp_cache_msync(drawing_canvas.getBuffer(), canvas_bytes,
                                          ESP_CACHE_MSYNC_FLAG_DIR_C2M), tag, "publish canvas pixels");
        ESP_RETURN_ON_ERROR(esp_cache_msync(destination, canvas_bytes, ESP_CACHE_MSYNC_FLAG_DIR_M2C),
                            tag, "invalidate mailbox pixels");
        const auto result = submit_dma.copy(destination);
        if (result != ESP_OK) {
            submit_dma.release();
            return result;
        }
        esp_psram_mspi_mb();
    } else {
        const auto* source = static_cast<const uint16_t*>(drawing_canvas.getBuffer());
        auto* pixels = static_cast<uint16_t*>(destination);
        for (int y = 0; y < height; ++y) {
            std::memcpy(pixels + y * canvas_width, source + y * drawing_canvas.width(),
                        width * sizeof(uint16_t));
            std::memset(pixels + y * canvas_width + width, 0,
                        (canvas_width - width) * sizeof(uint16_t));
        }
        std::memset(pixels + height * canvas_width, 0,
                    (canvas_height - height) * canvas_width * sizeof(uint16_t));
        ESP_RETURN_ON_ERROR(esp_cache_msync(destination, canvas_bytes,
                                          ESP_CACHE_MSYNC_FLAG_DIR_C2M), tag, "publish mailbox pixels");
    }
    portENTER_CRITICAL(&mailbox_lock);
    frame_pending = true;
    portEXIT_CRITICAL(&mailbox_lock);
    xTaskNotifyGive(presenter);
    drawing_canvas.clearClipRect();
    return ESP_OK;
}

namespace {

template <unsigned Row>
void write_pattern_row(uint16_t* pixels, int left, int end, uint16_t color)
{
    if constexpr (Row == 0x0) {
        return;
    } else if constexpr (Row == 0xF) {
        std::fill(pixels + left, pixels + end, color);
    } else {
        // Align to the tile in canvas coordinates, even when the span is clipped.
        const int first_tile = std::min(end, (left + 3) & ~3);
        for (; left < first_tile; ++left) {
            if (Row & (1u << (left & 3))) pixels[left] = color;
        }
        for (; left + 4 <= end; left += 4) {
            if constexpr (Row & 0x1) pixels[left] = color;
            if constexpr (Row & 0x2) pixels[left + 1] = color;
            if constexpr (Row & 0x4) pixels[left + 2] = color;
            if constexpr (Row & 0x8) pixels[left + 3] = color;
        }
        for (; left < end; ++left) {
            if (Row & (1u << (left & 3))) pixels[left] = color;
        }
    }
}

constexpr std::array pattern_row_writers{
    write_pattern_row<0x0>, write_pattern_row<0x1>, write_pattern_row<0x2>, write_pattern_row<0x3>,
    write_pattern_row<0x4>, write_pattern_row<0x5>, write_pattern_row<0x6>, write_pattern_row<0x7>,
    write_pattern_row<0x8>, write_pattern_row<0x9>, write_pattern_row<0xA>, write_pattern_row<0xB>,
    write_pattern_row<0xC>, write_pattern_row<0xD>, write_pattern_row<0xE>, write_pattern_row<0xF>,
};

class PatternSpans {
public:
    PatternSpans(uint16_t color, const FillPattern& pattern)
        : pixels_(static_cast<uint16_t*>(drawing_canvas.getBuffer())), pitch_(drawing_canvas.width()),
          color_(color), pattern_(pattern)
    {
        drawing_canvas.getClipRect(&clip_x_, &clip_y_, &clip_width_, &clip_height_);
    }

    void write_span(int y, int left, int end_x) const
    {
        pattern_row_writers[pattern_.rows[y & 3]](pixels_ + y * pitch_, left, end_x, color_);
    }

    void write_rect(int x, int y, int width, int height) const
    {
        const int left = std::max(x, int(clip_x_));
        const int end_x = std::min(x + width, int(clip_x_ + clip_width_));
        if (left >= end_x) return;
        const int end_y = std::min(y + height, int(clip_y_ + clip_height_));
        for (y = std::max(y, int(clip_y_)); y < end_y; ++y) {
            write_span(y, left, end_x);
        }
    }

    bool intersects(int left, int top, int right, int bottom) const
    {
        return clip_width_ > 0 && clip_height_ > 0 && left < clip_x_ + clip_width_ && right >= clip_x_
            && top < clip_y_ + clip_height_ && bottom >= clip_y_;
    }

private:
    uint16_t* pixels_;
    int pitch_;
    uint16_t color_;
    const FillPattern& pattern_;
    int32_t clip_x_, clip_y_, clip_width_, clip_height_;
};

struct TrianglePoint { int x, y; };

int64_t triangle_edge(TrianglePoint a, TrianglePoint b, TrianglePoint p)
{
    return int64_t(b.x - a.x) * (p.y - a.y) - int64_t(b.y - a.y) * (p.x - a.x);
}

struct TriangleScanEdge {
    TrianglePoint start, end;
    float step;

    TriangleScanEdge(TrianglePoint a, TrianglePoint b)
        : start(a), end(b), step(a.y == b.y ? 0.0f : float(b.x - a.x) / float(b.y - a.y)) {}

    int x_at(int y, bool round_up) const
    {
        if (y == end.y) return end.x;
        const float x = float(start.x) + float(y - start.y) * step;
        const int whole = static_cast<int>(x);
        return whole + (round_up ? (x > float(whole)) : -(x < float(whole)));
    }
};

template <typename DrawSpan>
void draw_triangle_spans(TrianglePoint a, TrianglePoint b, TrianglePoint c, DrawSpan draw_span)
{
    TrianglePoint vertices[] = {a, b, c};
    std::sort(vertices, vertices + 3, [](TrianglePoint a, TrianglePoint b) { return a.y < b.y; });
    const auto [top, middle, bottom] = vertices;

    const int64_t area = triangle_edge(top, middle, bottom);
    if (area == 0) return;

    int32_t clip_x, clip_y, clip_width, clip_height;
    drawing_canvas.getClipRect(&clip_x, &clip_y, &clip_width, &clip_height);
    const int first_y = std::max(top.y, int(clip_y));
    const int end_y = std::min(bottom.y + 1, int(clip_y + clip_height));
    if (first_y >= end_y || clip_width == 0) return;

    const TriangleScanEdge long_side(top, bottom);
    const TriangleScanEdge upper_side(top, middle);
    const TriangleScanEdge lower_side(middle, bottom);
    const bool middle_on_right = area > 0;
    for (int y = first_y; y < end_y; ++y) {
        const auto& short_side = (y < middle.y || middle.y == bottom.y) ? upper_side : lower_side;
        const int long_edge = long_side.x_at(y, middle_on_right);
        const int short_edge = short_side.x_at(y, !middle_on_right);
        const int span_left = middle_on_right ? long_edge : short_edge;
        const int left = std::max(int(clip_x), span_left);
        const int right = std::min(int(clip_x + clip_width - 1), middle_on_right ? short_edge : long_edge);
        if (left <= right) draw_span(y, span_left, left, right);
    }
}

float wrap_sprite_coordinate(float value, float period)
{
    if (value >= 0 && value < period) return value;
    float result = std::fmod(value, period);
    if (result < 0) result += period;
    return result < period ? result : 0.0f;
}

float wrap_sprite_step(float step, float period)
{
    if (std::abs(step) >= period) step = std::fmod(step, period);
    // Keep small negative steps negative to preserve their precision.
    const float half_period = period * 0.5f;
    if (step > half_period) step -= period;
    else if (step < -half_period) step += period;
    return step;
}

float advance_sprite_coordinate(float value, float step, float period)
{
    value += step;
    if (value < 0.0f) value += period;
    if (value >= period) value -= period;
    return value;
}

struct TriangleTextureAxis {
    float a, b, c;
    float period;
    float scaled_period;
    float scale = 1.0f;
    float step;

    TriangleTextureAxis(float a, float b, float c, int size, float step_b, float step_c, float area)
        : a(a), b(b), c(c), period(size)
    {
        // Leave room for differences and edge weights even at the limits of Lua's float range.
        constexpr float large_scale = 0x1p36f;
        if (std::max({std::abs(a), std::abs(b), std::abs(c)}) > std::numeric_limits<float>::max() / large_scale) {
            this->a /= large_scale;
            this->b /= large_scale;
            this->c /= large_scale;
            scale = large_scale;
        }
        scaled_period = period / scale;
        const float gradient = ((this->b - this->a) * step_b + (this->c - this->a) * step_c) / area;
        step = wrap_sprite_step(gradient, scaled_period) * scale;
    }

    float start(float weight_a, float weight_b, float weight_c, float area) const
    {
        const float value = (weight_a * a + weight_b * b + weight_c * c) / area;
        return wrap_sprite_coordinate(value, scaled_period) * scale;
    }

    void advance(float& value) const
    {
        value = advance_sprite_coordinate(value, step, period);
    }
};

} // namespace

void fill_rect(int x, int y, int width, int height, uint16_t color, const FillPattern& pattern)
{
    if (pattern.mask == 0) return;
    if (pattern.mask != UINT16_MAX) {
        PatternSpans(color, pattern).write_rect(x, y, width, height);
        return;
    }

    const int right = std::min(int(drawing_canvas.width()), x + width);
    const int bottom = std::min(int(drawing_canvas.height()), y + height);
    x = std::max(0, x);
    y = std::max(0, y);
    width = right - x;
    height = bottom - y;
    if (width <= 0 || height <= 0) return;

    drawing_canvas.fillRect(x, y, width, height, color);
}

void fill_circle(int x, int y, int radius, uint16_t color, const FillPattern& pattern)
{
    if (pattern.mask == 0) return;
    if (pattern.mask == UINT16_MAX) {
        drawing_canvas.fillCircle(x, y, radius, color);
        return;
    }

    const PatternSpans spans(color, pattern);
    if (!spans.intersects(x - radius, y - radius, x + radius, y + radius)) return;
    spans.write_rect(x - radius, y, 2 * radius + 1, 1);
    if (radius == 0) return;

    // Match the integer stepping in LovyanGFX's fillCircleHelper.
    int outer = radius;
    int inner = 0;
    int error = 1 - radius;
    int step_x = 1;
    int step_y = -2 * radius;
    do {
        const int previous_inner = inner;
        while (error < 0) {
            ++inner;
            step_x += 2;
            error += step_x;
        }
        step_y += 2;
        error += step_y;

        const int height = inner - previous_inner;
        if (height > 0) {
            spans.write_rect(x - outer, y + previous_inner + 1, 2 * outer + 1, height);
            spans.write_rect(x - outer, y - inner, 2 * outer + 1, height);
        }
        spans.write_rect(x - inner, y + outer, 2 * inner + 1, 1);
        spans.write_rect(x - inner, y - outer, 2 * inner + 1, 1);
    } while (inner < --outer);
}

void fill_triangle(int x0, int y0, int x1, int y1, int x2, int y2, uint16_t color,
                   const FillPattern& pattern)
{
    if (pattern.mask == 0) return;
    if (pattern.mask != UINT16_MAX) {
        const PatternSpans spans(color, pattern);
        draw_triangle_spans({x0, y0}, {x1, y1}, {x2, y2}, [&](int y, int, int left, int right) {
            spans.write_span(y, left, right + 1);
        });
        return;
    }

    drawing_canvas.setColor(color);
    drawing_canvas.startWrite();
    draw_triangle_spans({x0, y0}, {x1, y1}, {x2, y2}, [](int y, int, int left, int right) {
        drawing_canvas.writeFillRectPreclipped(left, y, right - left + 1, 1);
    });
    drawing_canvas.endWrite();
}

void draw_textured_triangle(lgfx::PPA_Sprite& sprite, const int xy[6], const float uv[6])
{
    const TrianglePoint a{xy[0], xy[1]}, b{xy[2], xy[3]}, c{xy[4], xy[5]};
    const int64_t signed_area = triangle_edge(a, b, c);
    if (signed_area == 0) return;
    const int direction = signed_area > 0 ? 1 : -1;
    const int64_t area = signed_area * direction;
    const float step_b = float((c.y - a.y) * direction);
    const float step_c = float((a.y - b.y) * direction);

    const int width = sprite.width();
    const int height = sprite.height();
    if (width <= 0 || height <= 0) return;
    const TriangleTextureAxis u(uv[0], uv[2], uv[4], width, step_b, step_c, float(area));
    const TriangleTextureAxis v(uv[1], uv[3], uv[5], height, step_b, step_c, float(area));
    const int pitch = drawing_canvas.width();
    const auto* pixels = static_cast<const uint16_t*>(sprite.getBuffer());
    auto* destination = static_cast<uint16_t*>(drawing_canvas.getBuffer());

    draw_triangle_spans(a, b, c, [&](int y, int span_left, int left, int right) {
        auto* out = destination + y * pitch;
        // Restart periodically to bound float drift. Anchor the blocks to the
        // unclipped span so clipping selects the same texels as a full draw.
        constexpr int block_width = 32;
        const int first_block = left - (left - span_left) % block_width;
        for (int block_x = first_block; block_x <= right; block_x += block_width) {
            const int64_t weight_b = triangle_edge(c, a, {block_x, y}) * direction;
            const int64_t weight_c = triangle_edge(a, b, {block_x, y}) * direction;
            const float weight_a = float(area - weight_b - weight_c);
            float sample_u = u.start(weight_a, float(weight_b), float(weight_c), float(area));
            float sample_v = v.start(weight_a, float(weight_b), float(weight_c), float(area));
            const int first_x = std::max(left, block_x);
            const int end_x = std::min(right + 1, block_x + block_width);
            for (int x = block_x; x < first_x; ++x) {
                u.advance(sample_u);
                v.advance(sample_v);
            }
            for (int x = first_x; x < end_x; ++x) {
                out[x] = pixels[int(sample_v) * width + int(sample_u)];
                u.advance(sample_u);
                v.advance(sample_v);
            }
        }
    });
}

void draw_sprite(lgfx::PPA_Sprite& sprite, int x, int y, int32_t transparent,
                 bool flip_x, bool flip_y)
{
    int32_t clip_x, clip_y, clip_width, clip_height;
    drawing_canvas.getClipRect(&clip_x, &clip_y, &clip_width, &clip_height);
    const int destination_x = std::max({0, x, int(clip_x)});
    const int destination_y = std::max({0, y, int(clip_y)});
    const int right = std::min({int(drawing_canvas.width()), x + int(sprite.width()), int(clip_x + clip_width)});
    const int bottom = std::min({int(drawing_canvas.height()), y + int(sprite.height()), int(clip_y + clip_height)});
    const int width = right - destination_x;
    const int height = bottom - destination_y;
    if (width <= 0 || height <= 0) return;
    const int source_x = destination_x - x;
    const int source_y = destination_y - y;
    // Reserve PPA for large unflipped visible blocks; all other blits use
    // the shared CPU loop below, including when PPA is unavailable or fails.
    if (!flip_x && !flip_y && ppa_blend && width * height >= ppa_sprite_min_pixels) {
        // The library's convenience blend API requires equal-size pictures.
        // Configure the clipped blocks explicitly to support arbitrary sprites.
        auto config = ppa_blend->config();
        config.in_fg = {};
        config.in_fg.buffer = sprite.getBuffer();
        config.in_fg.pic_w = sprite.width();
        config.in_fg.pic_h = sprite.height();
        config.in_fg.block_w = width;
        config.in_fg.block_h = height;
        config.in_fg.block_offset_x = source_x;
        config.in_fg.block_offset_y = source_y;
        config.in_fg.blend_cm = PPA_BLEND_COLOR_MODE_RGB565;
        config.in_bg = config.in_fg;
        config.in_bg.buffer = drawing_canvas.getBuffer();
        config.in_bg.pic_w = int(drawing_canvas.width());
        config.in_bg.pic_h = int(drawing_canvas.height());
        config.in_bg.block_offset_x = destination_x;
        config.in_bg.block_offset_y = destination_y;
        config.out = {};
        config.out.buffer = drawing_canvas.getBuffer();
        config.out.buffer_size = target_capacity;
        config.out.pic_w = int(drawing_canvas.width());
        config.out.pic_h = int(drawing_canvas.height());
        config.out.block_offset_x = destination_x;
        config.out.block_offset_y = destination_y;
        config.out.blend_cm = PPA_BLEND_COLOR_MODE_RGB565;
        config.fg_alpha_fix_val = 255;
        config.bg_alpha_fix_val = 255;
        config.fg_ck_en = transparent >= 0;
        if (config.fg_ck_en) {
            lgfx::rgb888_t key_color;
            key_color = lgfx::rgb565_t(static_cast<uint16_t>(transparent));
            const auto key = lgfx::ppa_color_convert_rgb888(key_color);
            config.fg_ck_rgb_low_thres = key;
            config.fg_ck_rgb_high_thres = key;
            // Match exactly one RGB565 value regardless of how the hardware
            // expands its 5/6-bit channels into the 8-bit comparison space.
            config.fg_ck_rgb_low_thres.r &= 0xf8;
            config.fg_ck_rgb_low_thres.g &= 0xfc;
            config.fg_ck_rgb_low_thres.b &= 0xf8;
            config.fg_ck_rgb_high_thres.r |= 0x07;
            config.fg_ck_rgb_high_thres.g |= 0x03;
            config.fg_ck_rgb_high_thres.b |= 0x07;
        }
        if (ppa_blend->exec(&config)) return;
    }
    // Both buffers use tightly packed native-endian RGB565. Mirror the
    // source coordinates after clipping; never modify the source pixels.
    const auto* pixels = static_cast<const uint16_t*>(sprite.getBuffer());
    auto* destination = static_cast<uint16_t*>(drawing_canvas.getBuffer());
    const int first_x = flip_x ? sprite.width() - 1 - source_x : source_x;
    const int first_y = flip_y ? sprite.height() - 1 - source_y : source_y;
    const int step_x = flip_x ? -1 : 1;
    const int step_y = flip_y ? -1 : 1;
    for (int row = 0; row < height; ++row) {
        const auto* source = pixels + (first_y + row * step_y) * sprite.width() + first_x;
        auto* out = destination + (destination_y + row) * int(drawing_canvas.width()) + destination_x;
        if (transparent < 0) {
            if (!flip_x) {
                std::memcpy(out, source, width * sizeof(uint16_t));
            } else {
                for (int column = 0; column < width; ++column) out[column] = source[-column];
            }
        } else {
            const auto key = static_cast<uint16_t>(transparent);
            for (int column = 0; column < width; ++column) {
                const auto color = source[column * step_x];
                if (color != key) out[column] = color;
            }
        }
    }
}

void draw_sprite_region(lgfx::PPA_Sprite& sprite, int sx, int sy, int sw, int sh,
                        int dx, int dy, int dw, int dh, int32_t transparent,
                        bool flip_x, bool flip_y)
{
    if (sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) return;
    int32_t clip_x, clip_y, clip_width, clip_height;
    drawing_canvas.getClipRect(&clip_x, &clip_y, &clip_width, &clip_height);
    const int left = std::max({0, dx, int(clip_x)});
    const int top = std::max({0, dy, int(clip_y)});
    const int right = std::min({int64_t(drawing_canvas.width()), int64_t(dx) + dw,
                                int64_t(clip_x) + clip_width});
    const int bottom = std::min({int64_t(drawing_canvas.height()), int64_t(dy) + dh,
                                 int64_t(clip_y) + clip_height});
    if (left >= right || top >= bottom) return;

    // Compute horizontal mappings in bounded chunks so wide targets fit the worker
    // stack. Mirror within the requested source rectangle before bounds checks.
    constexpr int column_capacity = 256;
    int source_columns[column_capacity];
    for (int chunk = left; chunk < right; chunk += column_capacity) {
        const int chunk_right = std::min(right, chunk + column_capacity);
        for (int x = chunk; x < chunk_right; ++x) {
            const int sample = (int64_t(x) - dx) * sw / dw;
            const int64_t source_x = int64_t(sx) + (flip_x ? sw - 1 - sample : sample);
            source_columns[x - chunk] = source_x >= 0 && source_x < sprite.width()
                                         ? static_cast<int>(source_x) : -1;
        }
        const auto* pixels = static_cast<const uint16_t*>(sprite.getBuffer());
        auto* destination = static_cast<uint16_t*>(drawing_canvas.getBuffer());
        const auto key = static_cast<uint16_t>(transparent);
        for (int y = top; y < bottom; ++y) {
            const int sample = (int64_t(y) - dy) * sh / dh;
            const int64_t source_y = int64_t(sy) + (flip_y ? sh - 1 - sample : sample);
            if (source_y < 0 || source_y >= sprite.height()) continue;
            const auto* source = pixels + source_y * sprite.width();
            auto* out = destination + y * int(drawing_canvas.width()) + chunk;
            for (int column = 0; column < chunk_right - chunk; ++column) {
                const int source_x = source_columns[column];
                if (source_x < 0) continue;
                const auto color = source[source_x];
                if (transparent < 0 || color != key) out[column] = color;
            }
        }
    }
}

void draw_textured_line(lgfx::PPA_Sprite& sprite, int x0, int y0, int x1, int y1,
                        float sx, float sy, float sdx, float sdy)
{
    const int width = sprite.width();
    const int height = sprite.height();
    if (width <= 0 || height <= 0 || !std::isfinite(sx) || !std::isfinite(sy)
        || !std::isfinite(sdx) || !std::isfinite(sdy)) return;

    // Reduce before adding so even very large finite inputs cannot overflow.
    const float period_x = width;
    const float period_y = height;
    sx = wrap_sprite_coordinate(sx, period_x);
    sy = wrap_sprite_coordinate(sy, period_y);
    sdx = wrap_sprite_step(sdx, period_x);
    sdy = wrap_sprite_step(sdy, period_y);
    const auto advance = [&] {
        sx = advance_sprite_coordinate(sx, sdx, period_x);
        sy = advance_sprite_coordinate(sy, sdy, period_y);
    };

    int32_t clip_x, clip_y, clip_width, clip_height;
    drawing_canvas.getClipRect(&clip_x, &clip_y, &clip_width, &clip_height);
    const int left = std::max(0, int(clip_x));
    const int top = std::max(0, int(clip_y));
    const int right = std::min(int(drawing_canvas.width()), int(clip_x + clip_width));
    const int bottom = std::min(int(drawing_canvas.height()), int(clip_y + clip_height));
    if (left >= right || top >= bottom) return;
    const auto* pixels = static_cast<const uint16_t*>(sprite.getBuffer());
    auto* destination = static_cast<uint16_t*>(drawing_canvas.getBuffer());

    if (y0 == y1 || x0 == x1) {
        const bool horizontal = y0 == y1;
        const int fixed = horizontal ? y0 : x0;
        if (fixed < (horizontal ? top : left)
            || fixed >= (horizontal ? bottom : right)) return;

        const int first = horizontal ? x0 : y0;
        const int last = horizontal ? x1 : y1;
        const int lower = horizontal ? left : top;
        const int upper = (horizontal ? right : bottom) - 1;
        if (std::max(first, last) < lower || std::min(first, last) > upper) return;
        const int start = std::clamp(first, lower, upper);
        const int end = std::clamp(last, lower, upper);

        // Keep the same floating-point accumulation as the general path,
        // including the clipped prefix, so texel boundaries do not shift.
        for (int skipped = std::abs(start - first); skipped > 0; --skipped) {
            advance();
        }
        const int direction = first <= last ? 1 : -1;
        const int stride = direction * (horizontal ? 1 : int(drawing_canvas.width()));
        const int offset = horizontal ? y0 * int(drawing_canvas.width()) + start : start * int(drawing_canvas.width()) + x0;
        auto* out = destination + offset;
        int remaining = std::abs(end - start) + 1;
        for (;;) {
            *out = pixels[static_cast<int>(sy) * width + static_cast<int>(sx)];
            if (--remaining == 0) return;
            out += stride;
            advance();
        }
    }

    const int dx = std::abs(x1 - x0);
    const int dy = -std::abs(y1 - y0);
    const int step_x = x0 < x1 ? 1 : -1;
    const int step_y = y0 < y1 ? 1 : -1;
    int error = dx + dy;
    for (;;) {
        if (x0 >= left && x0 < right && y0 >= top && y0 < bottom) {
            destination[y0 * int(drawing_canvas.width()) + x0] =
                pixels[static_cast<int>(sy) * width + static_cast<int>(sx)];
        }
        if (x0 == x1 && y0 == y1) break;
        const int twice_error = 2 * error;
        if (twice_error >= dy) { error += dy; x0 += step_x; }
        if (twice_error <= dx) { error += dx; y0 += step_y; }
        advance();
    }
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
