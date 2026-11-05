#include "sound.hpp"

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstring>
#include <new>

#include "audio.hpp"

namespace tabos::audio {
namespace {

uint16_t read_le16(const uint8_t* bytes)
{
    return bytes[0] | (static_cast<uint16_t>(bytes[1]) << 8);
}

uint32_t read_le32(const uint8_t* bytes)
{
    return read_le16(bytes) | (static_cast<uint32_t>(read_le16(bytes + 2)) << 16);
}

}

Sound* load_wav(const char* path, const char*& error)
{
    const std::unique_ptr<FILE, decltype(&std::fclose)> file(std::fopen(path, "rb"), std::fclose);
    if (!file) {
        error = "could not open WAV file";
        return nullptr;
    }

    error = "invalid or truncated WAV file";
    if (std::fseek(file.get(), 0, SEEK_END) != 0) {
        return nullptr;
    }
    const long file_size = std::ftell(file.get());
    uint8_t header[12];
    if (file_size < static_cast<long>(sizeof(header)) || std::fseek(file.get(), 0, SEEK_SET) != 0 ||
        std::fread(header, 1, sizeof(header), file.get()) != sizeof(header) ||
        std::memcmp(header, "RIFF", 4) != 0 || std::memcmp(header + 8, "WAVE", 4) != 0) {
        return nullptr;
    }
    const uint32_t riff_size = read_le32(header + 4);
    if (riff_size < 4 || riff_size > static_cast<unsigned long>(file_size - 8)) {
        return nullptr;
    }

    uint16_t channels = 0;
    long data_offset = -1;
    uint32_t data_size = 0;
    uint32_t remaining = riff_size - 4;
    while (remaining >= 8 && (channels == 0 || data_offset < 0)) {
        uint8_t chunk[8];
        if (std::fread(chunk, 1, sizeof(chunk), file.get()) != sizeof(chunk)) {
            return nullptr;
        }
        remaining -= sizeof(chunk);
        const uint32_t size = read_le32(chunk + 4);
        if (size > remaining) {
            return nullptr;
        }
        // Some writers omit padding on the final odd-sized chunk.
        uint32_t skip = size + ((size & 1u) && size < remaining);
        remaining -= skip;

        if (std::memcmp(chunk, "fmt ", 4) == 0) {
            uint8_t format[16];
            if (size < sizeof(format) || std::fread(format, 1, sizeof(format), file.get()) != sizeof(format)) {
                return nullptr;
            }
            channels = read_le16(format + 2);
            if (read_le16(format) != 1 || (channels != 1 && channels != 2) ||
                read_le32(format + 4) != sample_rate || read_le16(format + 12) != channels ||
                read_le16(format + 14) != 8) {
                error = "expected 8-bit PCM WAV at 22050 Hz, mono or stereo";
                return nullptr;
            }
            skip -= sizeof(format);
        } else if (std::memcmp(chunk, "data", 4) == 0 && data_offset < 0) {
            data_offset = std::ftell(file.get());
            if (data_offset < 0) {
                return nullptr;
            }
            data_size = size;
        }

        if (std::fseek(file.get(), skip, SEEK_CUR) != 0) {
            return nullptr;
        }
    }

    if (channels == 0 || data_offset < 0 || data_size == 0 || data_size % channels != 0 ||
        std::fseek(file.get(), data_offset, SEEK_SET) != 0) {
        return nullptr;
    }
    const std::size_t frame_count = data_size / channels;
    std::unique_ptr<int8_t[]> samples(new (std::nothrow) int8_t[frame_count]);
    if (!samples) {
        error = "could not allocate WAV samples";
        return nullptr;
    }

    std::array<uint8_t, 512> bytes;
    for (std::size_t offset = 0; offset < frame_count;) {
        const std::size_t count = std::min(frame_count - offset, bytes.size() / channels);
        if (std::fread(bytes.data(), channels, count, file.get()) != count) {
            return nullptr;
        }
        for (std::size_t i = 0; i < count; ++i) {
            const int left = static_cast<int>(bytes[i * channels]) - 128;
            samples[offset + i] = channels == 1 ? left : (left + bytes[i * channels + 1] - 128) / 2;
        }
        offset += count;
    }

    auto* sound = new (std::nothrow) Sound(std::move(samples), frame_count);
    error = sound ? nullptr : "could not allocate sound";
    return sound;
}

}
