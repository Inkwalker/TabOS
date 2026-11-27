#include "hid.hpp"

#include "input/usb_mouse.hpp"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "usb/hid_host.h"

#include <algorithm>
#include <array>
#include <atomic>

namespace tabos::usb::hid {
namespace {

constexpr const char* tag = "usb_hid";
constexpr UBaseType_t event_priority = 5;
constexpr unsigned max_report_bytes = 1024;

struct Binding {
    const Handler& handler;
    std::atomic<hid_host_device_handle_t> device{nullptr};
};

Binding bindings[] = {
    {input::usb_mouse_handler},
};

struct Connection {
    hid_host_device_handle_t device;
    BootProtocol boot_protocol;
};

QueueHandle_t connections;
TaskHandle_t setup_task;

bool accepts(const Binding& binding, BootProtocol protocol)
{
    return !binding.device.load()
        && (protocol == BootProtocol::none || binding.handler.boot_protocol == protocol);
}

void close_interface(hid_host_device_handle_t device)
{
    if (const auto status = hid_host_device_close(device); status != ESP_OK) {
        ESP_LOGW(tag, "Could not close HID interface: %s", esp_err_to_name(status));
    }
}

void dispatch_report(hid_host_device_handle_t device)
{
    uint8_t data[max_report_bytes];
    size_t length = 0;
    if (hid_host_device_get_raw_input_report_data(device, data, sizeof(data), &length) != ESP_OK) {
        return;
    }
    for (const auto& binding : bindings) {
        if (binding.device.load() == device) {
            binding.handler.on_report({data, length});
        }
    }
}

void interface_event(hid_host_device_handle_t device, hid_host_interface_event_t event, void*)
{
    if (event == HID_HOST_INTERFACE_EVENT_INPUT_REPORT) {
        dispatch_report(device);
        return;
    }

    const bool disconnected = event == HID_HOST_INTERFACE_EVENT_DISCONNECTED;
    if (!disconnected && event != HID_HOST_INTERFACE_EVENT_TRANSFER_ERROR) {
        return;
    }

    for (auto& binding : bindings) {
        if (binding.device.load() == device) {
            binding.handler.on_event(disconnected ? Event::disconnected : Event::transfer_error);
            if (disconnected) {
                binding.device.store(nullptr);
            }
        }
    }

    if (disconnected) {
        // The driver's first close releases transfers and calls this callback.
        // Close again to release the interface handle.
        close_interface(device);
    } else {
        ESP_LOGW(tag, "USB HID input transfer failed");
    }
}

void open_interface(Connection connection)
{
    const auto [device, boot_protocol] = connection;
    const hid_host_device_config_t config = {
        .callback = interface_event,
        .callback_arg = nullptr,
    };
    if (hid_host_device_open(device, &config) != ESP_OK) {
        return;
    }

    size_t length = 0;
    const auto* descriptor = hid_host_get_report_descriptor(device, &length);
    std::array<bool, std::size(bindings)> selected{};
    auto fallback = selected.size();
    esp_err_t status = ESP_ERR_NOT_SUPPORTED;
    for (std::size_t i = 0; i < selected.size(); ++i) {
        const auto& binding = bindings[i];
        if (!accepts(binding, boot_protocol)) {
            continue;
        }
        if (descriptor && binding.handler.parse_descriptor({descriptor, length})) {
            selected[i] = true;
            status = ESP_OK;
        }
        if (fallback == selected.size() && boot_protocol != BootProtocol::none
            && binding.handler.use_boot_protocol) {
            fallback = i;
        }
    }

    if (status == ESP_ERR_NOT_SUPPORTED && fallback != selected.size()) {
        status = hid_class_request_set_protocol(device, HID_REPORT_PROTOCOL_BOOT);
        if (status == ESP_OK) {
            bindings[fallback].handler.use_boot_protocol();
            selected[fallback] = true;
        }
    }

    if (status == ESP_OK) {
        status = hid_host_device_start(device);
    }
    if (status != ESP_OK) {
        if (status != ESP_ERR_NOT_SUPPORTED) {
            ESP_LOGW(tag, "Could not start HID interface: %s", esp_err_to_name(status));
        }
        close_interface(device);
        return;
    }

    // This setup task has priority over HID event dispatch on the same core,
    // so the handlers are published before the first input report is delivered.
    for (std::size_t i = 0; i < selected.size(); ++i) {
        if (selected[i]) {
            bindings[i].handler.on_event(Event::connected);
            bindings[i].device.store(device);
        }
    }
}

bool has_available_handler(BootProtocol protocol)
{
    return std::any_of(std::begin(bindings), std::end(bindings),
                       [protocol](const Binding& binding) { return accepts(binding, protocol); });
}

void handle_connections(void*)
{
    Connection connection;
    while (true) {
        if (xQueueReceive(connections, &connection, portMAX_DELAY) == pdTRUE
            && has_available_handler(connection.boot_protocol)) {
            open_interface(connection);
        }
    }
}

void device_event(hid_host_device_handle_t device, hid_host_driver_event_t event, void*)
{
    hid_host_dev_params_t params;
    if (event != HID_HOST_DRIVER_EVENT_CONNECTED || hid_host_device_get_params(device, &params) != ESP_OK) {
        return;
    }

    auto protocol = BootProtocol::none;
    if (params.sub_class == HID_SUBCLASS_BOOT_INTERFACE) {
        switch (params.proto) {
        case HID_PROTOCOL_KEYBOARD: protocol = BootProtocol::keyboard; break;
        case HID_PROTOCOL_MOUSE: protocol = BootProtocol::mouse; break;
        }
    }
    const Connection connection{device, protocol};
    if (has_available_handler(protocol) && xQueueSend(connections, &connection, 0) != pdTRUE) {
        ESP_LOGW(tag, "USB HID connection queue is full");
    }
}

void stop_setup_task()
{
    if (setup_task) {
        vTaskDelete(setup_task);
        setup_task = nullptr;
    }
    if (connections) {
        vQueueDelete(connections);
        connections = nullptr;
    }
}

}

esp_err_t start(int core)
{
    connections = xQueueCreate(8, sizeof(Connection));
    // Control requests block until the HID event task dispatches completions.
    // On the same core, setup then resumes before a later disconnect can
    // cause the driver to free the report descriptor.
    if (!connections || xTaskCreatePinnedToCore(handle_connections, "usb_hid_setup", 4096, nullptr,
                                               event_priority + 1, &setup_task, core) != pdPASS) {
        stop_setup_task();
        return ESP_ERR_NO_MEM;
    }

    const hid_host_driver_config_t config = {
        .create_background_task = true,
        .task_priority = event_priority,
        .stack_size = 4096,
        .core_id = core,
        .callback = device_event,
        .callback_arg = nullptr,
    };
    const auto status = hid_host_install(&config);
    if (status != ESP_OK) {
        stop_setup_task();
    }
    return status;
}

void stop()
{
    hid_host_uninstall();
    stop_setup_task();
}

}
