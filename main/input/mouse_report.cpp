#include "mouse_report.hpp"

#include <algorithm>

namespace tabos::input {
namespace {

constexpr uint32_t generic_desktop = 0x00010000;
constexpr uint32_t button_page = 0x00090000;
constexpr uint32_t mouse_usage = generic_desktop | 0x02;
constexpr uint32_t usage_page_mask = 0xffff0000;
constexpr unsigned max_report_bits = MouseReportLayout::max_report_bytes * 8;

struct Globals {
    uint32_t usage_page = 0;
    uint32_t size = 0;
    uint32_t count = 0;
    uint8_t report_id = 0;
    bool is_signed = false;
};

struct LocalUsages {
    struct Range {
        uint32_t first;
        uint32_t last;
    };

    std::array<Range, 32> ranges;
    unsigned count = 0;
    uint32_t minimum = 0;

    void add(uint32_t first, uint32_t last)
    {
        if (count < ranges.size() && first <= last) {
            ranges[count++] = {first, last};
        }
    }

    uint32_t at(unsigned index) const
    {
        for (unsigned i = 0; i < count; ++i) {
            const auto [first, last] = ranges[i];
            if (index <= last - first) {
                return first + index;
            }
            index -= last - first + 1;
        }
        // A variable Input item repeats the final usage when its count is larger.
        return count ? ranges[count - 1].last : 0;
    }
};

}

bool MouseReportLayout::parse(std::span<const uint8_t> descriptor)
{
    field_count_ = 0;
    numbered_ = false;
    Globals global;
    std::array<Globals, 8> global_stack;
    unsigned stack_depth = 0;
    LocalUsages local;
    std::array<uint16_t, 256> offsets{};
    unsigned depth = 0;
    unsigned mouse_depth = 0;
    bool has_x = false;
    bool has_y = false;

    while (!descriptor.empty()) {
        const auto header = descriptor.front();
        descriptor = descriptor.subspan(1);
        if (header == 0xfe) {
            if (descriptor.size() < 2 || descriptor.size() < 2u + descriptor.front()) {
                return false;
            }
            descriptor = descriptor.subspan(2u + descriptor.front());
            continue;
        }

        const unsigned size_code = header & 3;
        const unsigned size = size_code == 3 ? 4 : size_code;
        if (descriptor.size() < size) {
            return false;
        }
        uint32_t value = 0;
        for (unsigned i = 0; i < size; ++i) {
            value |= uint32_t(descriptor[i]) << (8 * i);
        }
        const bool negative = size && (descriptor[size - 1] & 0x80);
        descriptor = descriptor.subspan(size);
        const uint32_t usage = size == 4 ? value : global.usage_page | value;
        const auto tag = header & 0xfc;

        // Short item tags include both the item type and the item tag.
        switch (tag) {
        case 0x04: global.usage_page = (value & 0xffff) << 16; break;
        case 0x14: global.is_signed = negative; break;
        case 0x74: global.size = value; break;
        case 0x84:
            if (!value || value > 255) {
                return false;
            }
            global.report_id = value;
            numbered_ = true;
            break;
        case 0x94: global.count = value; break;
        case 0xa4:
            if (stack_depth == global_stack.size()) {
                return false;
            }
            global_stack[stack_depth++] = global;
            break;
        case 0xb4:
            if (!stack_depth) {
                return false;
            }
            global = global_stack[--stack_depth];
            break;
        case 0x08: local.add(usage, usage); break;
        case 0x18: local.minimum = usage; break;
        case 0x28: local.add(local.minimum, usage); break;
        case 0xa0: // Collection
            ++depth;
            if (!mouse_depth && value == 1 && local.at(0) == mouse_usage) {
                mouse_depth = depth;
            }
            break;
        case 0xc0: // End Collection
            if (!depth) {
                return false;
            }
            if (depth-- == mouse_depth) {
                mouse_depth = 0;
            }
            break;
        case 0x80: { // Input
            auto& offset = offsets[global.report_id];
            const auto bits = uint64_t(global.size) * global.count;
            if (offset + bits > max_report_bits) {
                offset = max_report_bits + 1;
                if (mouse_depth) {
                    return false;
                }
                break;
            }
            // Parse Variable data fields inside the Mouse application only.
            if (mouse_depth && (value & 0x03) == 0x02 && global.size && global.size <= 32) {
                for (unsigned i = 0; i < global.count; ++i) {
                    const auto field_usage = local.at(i);
                    const auto number = field_usage & ~usage_page_mask;
                    uint8_t mapped = 0;
                    if ((field_usage & usage_page_mask) == button_page && number >= 1 && number <= 32) {
                        mapped = number;
                    } else if (value & 0x04) { // Relative
                        switch (field_usage) {
                        case generic_desktop | 0x30: mapped = x; has_x = true; break;
                        case generic_desktop | 0x31: mapped = y; has_y = true; break;
                        case generic_desktop | 0x38: mapped = wheel; break;
                        }
                    }
                    if (mapped) {
                        if (field_count_ == fields_.size()) {
                            return false;
                        }
                        fields_[field_count_++] = {uint16_t(offset + i * global.size),
                                                   uint8_t(global.size), global.report_id,
                                                   mapped, global.is_signed};
                    }
                }
            }
            offset += bits;
            break;
        }
        }

        if ((header & 0x0c) == 0) { // Main items consume local items.
            local.count = 0;
            local.minimum = 0;
        }
    }

    return has_x && has_y && depth == 0 && stack_depth == 0
        && (!numbered_ || std::none_of(fields_.begin(), fields_.begin() + field_count_,
                                      [](const Field& field) { return field.report_id == 0; }));
}

void MouseReportLayout::use_boot_protocol()
{
    numbered_ = false;
    fields_[0] = {0, 1, 0, 1, false};
    fields_[1] = {1, 1, 0, 2, false};
    fields_[2] = {2, 1, 0, 3, false};
    fields_[3] = {8, 8, 0, x, true};
    fields_[4] = {16, 8, 0, y, true};
    field_count_ = 5;
}

bool MouseReportLayout::decode(std::span<const uint8_t> data, MouseReport& report) const
{
    if (data.empty()) {
        return false;
    }
    const auto id = numbered_ ? data.front() : 0;
    if (numbered_) {
        data = data.subspan(1);
    }
    report = {};
    bool matched = false;
    for (unsigned i = 0; i < field_count_; ++i) {
        const auto& field = fields_[i];
        if (field.report_id != id) {
            continue;
        }
        if (unsigned(field.offset) + field.size > data.size() * 8) {
            return false;
        }
        matched = true;
        uint32_t raw = 0;
        for (unsigned bit = 0; bit < field.size; ++bit) {
            const auto offset = field.offset + bit;
            raw |= uint32_t((data[offset / 8] >> (offset % 8)) & 1) << bit;
        }
        int64_t value = raw;
        if (field.is_signed && (raw & (uint32_t{1} << (field.size - 1)))) {
            value -= int64_t{1} << field.size;
        }
        switch (field.usage) {
        case x: report.dx += value; break;
        case y: report.dy += value; break;
        case wheel: report.wheel += value; break;
        default:
            const auto mask = uint32_t{1} << (field.usage - 1);
            report.button_mask |= mask;
            if (value) {
                report.buttons |= mask;
            }
            break;
        }
    }
    return matched;
}

}
