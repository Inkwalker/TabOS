#pragma once

#include <cstdio>

#include "LGFX_PPA.hpp"

namespace gfx {

struct Sprite {
    lgfx::PPA_Sprite canvas;

    Sprite() = default;
    Sprite(const Sprite&) = delete;
    Sprite& operator=(const Sprite&) = delete;
    ~Sprite()
    {
        // PPA_Sprite attaches externally allocated storage with setBuffer().
        // LGFX_Sprite::deleteSprite() detaches it without freeing it.
        auto* pixels = canvas.getBuffer();
        canvas.deleteSprite();
        heap_caps_free(pixels);
    }
};

// Returns an owning pointer on success or sets error to a static message.
Sprite* load_png(const char* path, const char*& error);

}
