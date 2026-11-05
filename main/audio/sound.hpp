#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <utility>

namespace tabos::audio {

class Sound {
public:
    Sound(std::unique_ptr<int8_t[]> samples, std::size_t size)
        : samples_(std::move(samples)), size_(size) {}

    std::size_t size() const { return size_; }
    int8_t sample(std::size_t index) const { return samples_[index]; }

    void retain() { references_.fetch_add(1, std::memory_order_relaxed); }
    void release()
    {
        if (references_.fetch_sub(1, std::memory_order_acq_rel) == 1) {
            delete this;
        }
    }

private:
    std::unique_ptr<int8_t[]> samples_;
    std::size_t size_;
    std::atomic<unsigned> references_{1};
};

struct ReleaseSound {
    void operator()(Sound* sound) const { sound->release(); }
};
using SoundRef = std::unique_ptr<Sound, ReleaseSound>;

// Returns one owning reference on success or sets error to a static message.
Sound* load_wav(const char* path, const char*& error);

}
