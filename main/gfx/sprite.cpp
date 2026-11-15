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

Sprite* create_sprite(int width, int height, const char*& error)
{
    if (width <= 0 || height <= 0 || width > INT16_MAX || height > INT16_MAX) {
        error = "sprite dimensions must be from 1 to 32767";
        return nullptr;
    }
    std::unique_ptr<Sprite> sprite(new (std::nothrow) Sprite);
    if (!sprite) {
        error = "cannot allocate sprite";
        return nullptr;
    }
    auto& image = sprite->canvas;
    // Set the native-endian format before attaching aligned external storage.
    // setColorDepth() reallocates existing buffers; createSprite() loses this format flag.
    image.setColorDepth(lgfx::color_depth_t::rgb565_nonswapped);
    const auto bytes = lgfx::lgfx_ppa_align_up(size_t(width) * height * sizeof(uint16_t));
    auto* pixels = heap_caps_aligned_calloc(LGFX_PPA_ALIGN_SIZE, 1, bytes,
                                          MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!pixels) {
        error = "cannot allocate sprite pixels";
        return nullptr;
    }
    image.setBuffer(pixels, width, height);
    error = nullptr;
    return sprite.release();
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

    std::unique_ptr<Sprite> sprite(create_sprite(width, height, error));
    if (!sprite) return nullptr;
    auto& image = sprite->canvas;
    if (!image.drawPngFile(path)) {
        error = "cannot decode PNG file";
        return nullptr;
    }
    error = nullptr;
    return sprite.release();
}

}
