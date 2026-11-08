#pragma once

#include <cstdio>

#include "M5GFX.h"

namespace gfx {

struct Sprite {
    M5Canvas canvas;
};

// Returns an owning pointer on success or sets error to a static message.
Sprite* load_png(const char* path, const char*& error);

}
