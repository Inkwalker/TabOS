#pragma once

#include <cstdint>

namespace tabos::usb::hid {
struct Handler;
}

namespace tabos::input {

struct MouseState {
    bool connected = false;
    int32_t dx = 0;
    int32_t dy = 0;
    int32_t wheel = 0;
    uint32_t buttons = 0;
    uint32_t pressed = 0;
    uint32_t released = 0;
};

extern const usb::hid::Handler usb_mouse_handler;
MouseState poll_mouse();

}
