#include "storage.hpp"

#include "driver/sdmmc_host.h"
#include "esp_log.h"
#include "esp_vfs_fat.h"

// Set to 1 to export the SD card over USB-C. The default keeps USB Serial/JTAG for debugging.
#ifndef TABOS_USB_MTP
#define TABOS_USB_MTP 1
#endif

#if TABOS_USB_MTP
#include "hal/usb_serial_jtag_ll.h"
#include "hal/usb_wrap_ll.h"
#include "tinyusb.h"
#include "tinyusb_default_config.h"
#include "tinyusb_mtp.h"
#include "tusb.h"
#endif

namespace tabos::storage {
namespace {

constexpr const char* tag = "storage";
constexpr const char* sd_path = "/sd";

#if TABOS_USB_MTP
void usb_event(tinyusb_event_t* event, void*)
{
    if (event->id == TINYUSB_EVENT_ATTACHED || event->id == TINYUSB_EVENT_DETACHED) {
        // Reset the MTP session and release any files from an interrupted transfer.
        tud_mtp_request_device_reset_cb(nullptr);
    }
}

esp_err_t start_mtp()
{
    tinyusb_mtp_driver_config_t mtp_config{};
    mtp_config.model = "Tab5";
    mtp_config.friendly_name = "Tab5";
    esp_err_t status = tinyusb_mtp_install_driver(&mtp_config);
    if (status != ESP_OK) {
        return status;
    }

    const tinyusb_mtp_storage_config_t storage_config = {
        .base_path = sd_path,
        .display_name = "SD Card",
        .removable = true,
    };
    tinyusb_mtp_storage_handle_t storage = nullptr;
    status = tinyusb_mtp_register_storage(&storage_config, &storage);
    if (status != ESP_OK) {
        tinyusb_mtp_uninstall_driver();
        return status;
    }
    tinyusb_config_t usb_config = TINYUSB_DEFAULT_CONFIG(usb_event);
    usb_config.port = TINYUSB_PORT_FULL_SPEED_0;

    // MTP uses PHY 0 (GPIO24/25), moving Serial/JTAG to PHY 1.
    // Disable its pads first: GPIO26/27 carry the Tab5's audio data/bit clock.
    const bool serial_jtag_pads_enabled = usb_serial_jtag_ll_phy_is_pad_enabled();
    usb_serial_jtag_ll_phy_enable_pad(false);
    usb_wrap_ll_phy_select(&USB_WRAP, 0);
    status = tinyusb_driver_install(&usb_config);
    if (status != ESP_OK) {
        usb_wrap_ll_phy_select(&USB_WRAP, 1);
        usb_serial_jtag_ll_phy_enable_pad(serial_jtag_pads_enabled);
        tinyusb_mtp_unregister_storage(storage);
        tinyusb_mtp_uninstall_driver();
    }
    return status;
}
#endif

}

void init()
{
    sdmmc_host_t host = SDMMC_HOST_DEFAULT();
    host.slot = SDMMC_HOST_SLOT_0;
    sdmmc_slot_config_t slot = SDMMC_SLOT_CONFIG_DEFAULT();
    slot.width = 4;

    esp_vfs_fat_mount_config_t mount_config = VFS_FAT_MOUNT_DEFAULT_CONFIG();
    mount_config.max_files = 12;
    const esp_err_t mount_status = esp_vfs_fat_sdmmc_mount(sd_path, &host, &slot, &mount_config, nullptr);
    if (mount_status != ESP_OK) {
        ESP_LOGW(tag, "Could not mount %s: %s", sd_path, esp_err_to_name(mount_status));
        return;
    }

#if TABOS_USB_MTP
    const esp_err_t mtp_status = start_mtp();
    if (mtp_status != ESP_OK) {
        ESP_LOGW(tag, "Could not start USB file transfer: %s", esp_err_to_name(mtp_status));
    }
#endif
}

}
