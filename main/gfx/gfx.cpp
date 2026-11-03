#include "gfx.hpp"

#include <atomic>
#include <cstring>
#include <utility>

#include "esp_cache.h"
#include "esp_check.h"
#include "esp_ipc.h"
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

    esp_err_t init();
    void release();
    bool available() const { return ready_; }
    esp_err_t copy_band(uint8_t* destination);

private:
    esp_err_t configure();

    gdma_channel_handle_t tx_ = nullptr;
    gdma_channel_handle_t rx_ = nullptr;
    gdma_link_list_handle_t source_list_ = nullptr;
    gdma_link_list_handle_t destination_list_ = nullptr;
    SemaphoreHandle_t done_ = nullptr;
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

esp_err_t CopyDma::init()
{
    const auto result = configure();
    ready_ = result == ESP_OK;
    if (!ready_) release();
    return result;
}

esp_err_t CopyDma::configure()
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
    config.max_data_burst_size = tx_burst_bytes;
    ESP_RETURN_ON_ERROR(gdma_config_transfer(tx_, &config), tag, "configure TX burst");
    config.max_data_burst_size = rx_burst_bytes;
    config.access_ext_mem = true;
    ESP_RETURN_ON_ERROR(gdma_config_transfer(rx_, &config), tag, "configure RX burst");

    gdma_link_list_config_t list_config{};
    list_config.item_alignment = 8; // Required by AXI GDMA.
    list_config.num_items = band_rows;
    ESP_RETURN_ON_ERROR(gdma_new_link_list(&list_config, &source_list_),
                        tag, "allocate TX descriptors");
    for (int row = 0; row < band_rows; ++row) {
        gdma_buffer_mount_config_t source{};
        source.buffer = staging[row / scale].pixels;
        source.buffer_alignment = tx_burst_bytes;
        source.length = row_bytes;
        if (row == band_rows - 1) {
            source.flags.mark_eof = true;
            source.flags.mark_final = GDMA_FINAL_LINK_TO_NULL;
        }
        ESP_RETURN_ON_ERROR(gdma_link_mount_buffers(source_list_, row, &source, 1, nullptr),
                            tag, "mount TX row");
    }

    // RX writes back descriptor state. Remount its destination after each completed band.
    list_config.num_items = esp_dma_calculate_node_count(band_bytes, dma_alignment,
                                                         descriptor_max_bytes);
    ESP_RETURN_ON_ERROR(gdma_new_link_list(&list_config, &destination_list_),
                        tag, "allocate RX descriptors");
    done_ = xSemaphoreCreateBinary();
    if (!done_) return ESP_ERR_NO_MEM;
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

    const auto result = dma_aligned ? transfer.copy_dma.init() : ESP_ERR_INVALID_ARG;
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

esp_err_t CopyDma::copy_band(uint8_t* destination)
{
    ESP_RETURN_ON_ERROR(esp_cache_msync(staging, sizeof(staging),
                                      ESP_CACHE_MSYNC_FLAG_DIR_C2M), tag, "publish staging pixels");
    gdma_buffer_mount_config_t target{};
    target.buffer = destination;
    target.buffer_alignment = dma_alignment;
    target.length = band_bytes;
    target.flags.mark_final = GDMA_FINAL_LINK_TO_NULL;
    ESP_RETURN_ON_ERROR(gdma_link_mount_buffers(destination_list_, 0, &target, 1, nullptr),
                        tag, "mount RX band");
    ESP_RETURN_ON_ERROR(gdma_start(rx_, gdma_link_get_head_addr(destination_list_)),
                        tag, "start copy RX");
    active_ = true;
    ESP_RETURN_ON_ERROR(gdma_start(tx_, gdma_link_get_head_addr(source_list_)),
                        tag, "start copy TX");
    // DMA must finish reading the staging buffer before the next band overwrites it.
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
        auto* destination = framebuffer + (band / band_columns) * band_bytes;
        const auto result = dma.copy_band(destination);
        if (result != ESP_OK) return result;
    }
    return ESP_OK;
}

void copy_to_screen(const M5Canvas& canvas, ScreenTransfer& transfer, uint8_t* framebuffer)
{
    const auto* pixels = static_cast<const uint16_t*>(canvas.getBuffer());
    if (transfer.copy_dma.available()) {
        const auto result = copy_frame_dma(pixels, transfer.copy_dma, framebuffer);
        if (result == ESP_OK) {
            // Match the IDF async-copy driver's PSRAM barrier before publishing DMA writes.
            esp_psram_mspi_mb();
            return;
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
