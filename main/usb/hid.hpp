#pragma once

#include "esp_err.h"

#include <cstdint>
#include <span>

namespace tabos::usb::hid {

enum class BootProtocol { none, keyboard, mouse };
enum class Event { connected, disconnected, transfer_error };

struct Handler {
    // Generic interfaces are inspected by every available handler. For boot
    // interfaces, only handlers for the advertised role are considered.
    BootProtocol boot_protocol;
    // Configure an idle handler and return true if the descriptor matches.
    bool (*parse_descriptor)(std::span<const uint8_t>);
    void (*use_boot_protocol)(); // Optional fallback for the advertised boot role.
    // Ignore report IDs owned by other handlers on a shared interface.
    void (*on_report)(std::span<const uint8_t>);
    void (*on_event)(Event);
};

// HID handlers have one active interface each. Several handlers can read the
// same Report Protocol interface. Callbacks run in USB tasks, should return
// promptly, and must not retain descriptor or report spans.
esp_err_t start(int core);
// Roll back installation before enumeration.
void stop();

}
