#include "host.hpp"
#include "hid.hpp"

#include "M5Unified.h"
#include "esp_intr_alloc.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "usb/usb_host.h"

#include <iterator>

namespace tabos::usb {
namespace {

constexpr const char* tag = "usb_host";
constexpr int task_core = 0;

struct ClassDriver {
    esp_err_t (*start)(int core);
    void (*stop)();
};

constexpr ClassDriver classes[] = {
    {hid::start, hid::stop},
};

void stop_classes(std::size_t count)
{
    while (count) {
        classes[--count].stop();
    }
}

void handle_events(void*)
{
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    uint32_t flags = 0;
    usb_host_lib_handle_events(0, &flags);
    if (const auto status = usb_host_lib_set_root_port_power(true); status != ESP_OK) {
        ESP_LOGW(tag, "Could not enable USB-A root port: %s", esp_err_to_name(status));
        stop_classes(std::size(classes));
        usb_host_uninstall();
        vTaskDelete(nullptr);
        return;
    }

    while (true) {
        if (usb_host_lib_handle_events(portMAX_DELAY, &flags) == ESP_OK) {
            if (flags & USB_HOST_LIB_EVENT_FLAGS_NO_CLIENTS) {
                usb_host_device_free_all();
            }
        } else {
            vTaskDelay(pdMS_TO_TICKS(10));
        }
    }
}

}

esp_err_t start()
{
    usb_host_config_t config{};
    config.root_port_unpowered = true;
    config.intr_flags = ESP_INTR_FLAG_LEVEL1;
    config.peripheral_map = BIT0; // USB-A uses the Tab5's High-Speed controller.
    if (const auto status = usb_host_install(&config); status != ESP_OK) {
        return status;
    }

    TaskHandle_t event_task = nullptr;
    if (xTaskCreatePinnedToCore(handle_events, "usb_host", 4096, nullptr,
                               4, &event_task, task_core) != pdPASS) {
        usb_host_uninstall();
        return ESP_ERR_NO_MEM;
    }

    for (std::size_t i = 0; i < std::size(classes); ++i) {
        if (const auto status = classes[i].start(task_core); status != ESP_OK) {
            stop_classes(i);
            vTaskDelete(event_task);
            usb_host_uninstall();
            return status;
        }
    }

    M5.Power.setExtOutput(true, m5::ext_port_mask_t::ext_USB);
    xTaskNotifyGive(event_task);
    return ESP_OK;
}

}
