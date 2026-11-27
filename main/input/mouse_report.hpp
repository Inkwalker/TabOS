#pragma once

#include <array>
#include <cstdint>
#include <span>

namespace tabos::input {

struct MouseReport {
    int64_t dx = 0;
    int64_t dy = 0;
    int64_t wheel = 0;
    uint32_t buttons = 0;
    uint32_t button_mask = 0;
};

class MouseReportLayout {
public:
    static constexpr unsigned max_report_bytes = 1024;

    bool parse(std::span<const uint8_t> descriptor);
    void use_boot_protocol();
    bool decode(std::span<const uint8_t> data, MouseReport& report) const;

private:
    enum Usage : uint8_t { x = 33, y, wheel }; // 1–32 are HID button usages.
    struct Field {
        uint16_t offset;
        uint8_t size;
        uint8_t report_id;
        uint8_t usage;
        bool is_signed;
    };

    std::array<Field, 64> fields_{};
    unsigned field_count_ = 0;
    bool numbered_ = false;
};

}
