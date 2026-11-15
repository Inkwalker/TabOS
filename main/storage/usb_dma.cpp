#include "sdkconfig.h"
#include "soc/soc_caps.h"

#if CONFIG_TINYUSB_MTP_ENABLED && SOC_CACHE_INTERNAL_MEM_VIA_L1CACHE

#include "device/dcd.h"
#include "esp_cache.h"

extern "C" bool __real_dcd_edpt_xfer(uint8_t rhport, uint8_t ep_addr, uint8_t* buffer,
                                    uint16_t total_bytes, bool is_isr);

extern "C" bool __wrap_dcd_edpt_xfer(uint8_t rhport, uint8_t ep_addr, uint8_t* buffer,
                                    uint16_t total_bytes, bool is_isr)
{
    if (tu_edpt_dir(ep_addr) == TUSB_DIR_OUT && buffer != nullptr && total_bytes != 0) {
        // MTP reuses its endpoint buffer after writing the container header. A dirty
        // cache line must not be evicted over bytes subsequently received by DMA.
        // TinyUSB endpoint buffers include cache-line alignment and tail padding.
        constexpr size_t alignment = CONFIG_CACHE_L1_CACHE_LINE_SIZE;
        const size_t sync_bytes = (static_cast<size_t>(total_bytes) + alignment - 1) & ~(alignment - 1);
        // TinyUSB's clean/invalidate helper combines two mutually exclusive IDF
        // directions. Use the IDF operation directly, then retain its existing
        // post-DMA invalidation in the controller driver.
        if (esp_cache_msync(buffer, sync_bytes,
                            ESP_CACHE_MSYNC_FLAG_DIR_C2M | ESP_CACHE_MSYNC_FLAG_INVALIDATE) != ESP_OK) {
            return false;
        }
    }
    return __real_dcd_edpt_xfer(rhport, ep_addr, buffer, total_bytes, is_isr);
}

#endif
