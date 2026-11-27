#include "usb_mouse.hpp"
#include "mouse_report.hpp"
#include "usb/hid.hpp"

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include <algorithm>
#include <limits>

namespace tabos::input {
namespace {

MouseReportLayout layout;
portMUX_TYPE state_lock = portMUX_INITIALIZER_UNLOCKED;
MouseState pending;

int32_t add_delta(int32_t total, int64_t delta)
{
    return std::clamp<int64_t>(total + delta, std::numeric_limits<int32_t>::min(),
                                             std::numeric_limits<int32_t>::max());
}

void read_report(std::span<const uint8_t> data)
{
    MouseReport report;
    if (!layout.decode(data, report)) {
        return;
    }

    taskENTER_CRITICAL(&state_lock);
    const auto buttons = (pending.buttons & ~report.button_mask) | report.buttons;
    pending.pressed |= buttons & ~pending.buttons;
    pending.released |= pending.buttons & ~buttons;
    pending.buttons = buttons;
    pending.dx = add_delta(pending.dx, report.dx);
    pending.dy = add_delta(pending.dy, report.dy);
    pending.wheel = add_delta(pending.wheel, report.wheel);
    taskEXIT_CRITICAL(&state_lock);
}

void on_event(usb::hid::Event event)
{
    taskENTER_CRITICAL(&state_lock);
    pending.released |= pending.buttons;
    pending.buttons = 0;
    pending.connected = event != usb::hid::Event::disconnected;
    taskEXIT_CRITICAL(&state_lock);

    if (event == usb::hid::Event::connected) {
        ESP_LOGI("usb_mouse", "USB mouse connected");
    }
}

}

const usb::hid::Handler usb_mouse_handler = {
    .boot_protocol = usb::hid::BootProtocol::mouse,
    .parse_descriptor = [](std::span<const uint8_t> data) { return layout.parse(data); },
    .use_boot_protocol = [] { layout.use_boot_protocol(); },
    .on_report = read_report,
    .on_event = on_event,
};

MouseState poll_mouse()
{
    taskENTER_CRITICAL(&state_lock);
    const auto frame = pending;
    pending = {.connected = frame.connected, .buttons = frame.buttons};
    taskEXIT_CRITICAL(&state_lock);
    return frame;
}

}
