#include "sprite.hpp"

#include <cstdio>
#include <cstring>
#include <memory>
#include <new>

namespace gfx {
namespace {

uint32_t png_integer(const uint8_t* bytes)
{
    return (uint32_t(bytes[0]) << 24) | (uint32_t(bytes[1]) << 16)
         | (uint32_t(bytes[2]) << 8) | uint32_t(bytes[3]);
}

}

Sprite* load_png(const char* path, const char*& error)
{
    // Read the PNG signature and IHDR dimensions before allocating pixel storage.
    std::unique_ptr<FILE, decltype(&std::fclose)> file(std::fopen(path, "rb"), std::fclose);
    if (!file) {
        error = "could not open PNG file";
        return nullptr;
    }
    uint8_t header[24];
    const auto count = std::fread(header, 1, sizeof(header), file.get());
    file.reset();
    constexpr uint8_t signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
    if (count != sizeof(header) || std::memcmp(header, signature, sizeof(signature)) != 0
        || png_integer(header + 8) != 13 || std::memcmp(header + 12, "IHDR", 4) != 0) {
        error = "invalid PNG header";
        return nullptr;
    }
    const auto width = png_integer(header + 16);
    const auto height = png_integer(header + 20);
    if (width == 0 || height == 0 || width > INT16_MAX || height > INT16_MAX) {
        error = "PNG dimensions must be from 1 to 32767";
        return nullptr;
    }

    std::unique_ptr<Sprite> sprite(new (std::nothrow) Sprite);
    if (!sprite) {
        error = "cannot allocate sprite";
        return nullptr;
    }
    auto& image = sprite->canvas;
    // Set the format before attaching pixels: LGFX_Sprite::setColorDepth()
    // reallocates an existing buffer, changing its alignment and ownership.
    // PPA_Sprite::createSprite() also truncates the native-endian format flag,
    // so use its allocator and attach the buffer without a bpp override.
    image.setColorDepth(lgfx::color_depth_t::rgb565_nonswapped);
    const auto bytes = lgfx::lgfx_ppa_align_up(width * height * sizeof(uint16_t));
    auto* pixels = lgfx::heap_alloc_ppa(bytes);
    if (!pixels) {
        pixels = heap_caps_aligned_calloc(LGFX_PPA_ALIGN_SIZE, 1, bytes,
                                          MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA);
    }
    if (!pixels) {
        error = "cannot allocate sprite pixels";
        return nullptr;
    }
    image.setBuffer(pixels, width, height);
    image.fillScreen(uint16_t(0));
    if (!image.drawPngFile(path)) {
        error = "cannot decode PNG file";
        return nullptr;
    }
    error = nullptr;
    return sprite.release();
}

}
