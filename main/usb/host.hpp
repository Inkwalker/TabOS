#pragma once

#include "esp_err.h"

namespace tabos::usb {

// Start USB-A after M5.begin(). USB classes register before enumeration.
esp_err_t start();

}
