"""Generate M5GFX's LGFXBase.cpp with guards for failed image row allocations."""

import argparse
from pathlib import Path


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f"Unrecognized M5GFX source near {old.splitlines()[0].strip()!r}")
    return source.replace(old, new, 1)


def prepare(source):
    source = replace_once(
        source,
        "    bgra8888_t* lineBuffer;\n"
        "    pixelcopy_t *pc;",
        "    bgra8888_t* lineBuffer;\n"
        "    pixelcopy_t *pc;\n"
        "    bool lineBufferAllocationFailed = false;\n\n"
        "    bool allocateLineBuffer()\n"
        "    {\n"
        "      lineBuffer = (bgra8888_t*)heap_alloc_dma(sizeof(bgra8888_t) * maxWidth);\n"
        "      lineBufferAllocationFailed = lineBuffer == nullptr;\n"
        "      return !lineBufferAllocationFailed;\n"
        "    }",
    )
    # The PNG and QOI decoders share these void callbacks. Stop drawing after
    # the first failure, then let the caller close the normal write transaction.
    for name in ("png_draw_alpha_callback", "png_draw_alpha_scale_callback"):
        start = (
            f"  static void {name}(void *user_data, uint32_t x, uint32_t y, "
            "uint_fast8_t div_x, size_t len, const uint8_t* argb)\n"
            "  {\n"
            "    auto p = (png_file_decoder_t*)user_data;"
        )
        source = replace_once(source, start, start + "\n    if (p->lineBufferAllocationFailed) return;")
    allocation = "p->lineBuffer = (bgra8888_t*)heap_alloc_dma(sizeof(bgra8888_t) * p->maxWidth);"
    source = replace_once(
        source,
        "          " + allocation,
        "          if (!p->allocateLineBuffer()) return;",
    )
    source = replace_once(
        source,
        "      " + allocation + "\n      p->pc->src_data = p->lineBuffer;",
        "      if (!p->allocateLineBuffer()) return;\n"
        "      p->pc->src_data = p->lineBuffer;",
    )
    for cleanup in ("    png.end();", "    lgfx_qoi_destroy(qoi);"):
        source = replace_once(
            source,
            cleanup + "\n\n    return res < 0 ? false : true;",
            cleanup + "\n\n    return res >= 0 && !png.lineBufferAllocationFailed;",
        )
    return replace_once(
        source,
        "    void* rgbBuffer = heap_alloc_dma(w * 3);",
        "    void* rgbBuffer = heap_alloc_dma(w * 3);\n"
        "    if (rgbBuffer == nullptr)\n"
        "    {\n"
        "      *datalen = 0;\n"
        "      return nullptr;\n"
        "    }",
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    generated = prepare(args.source.read_text(encoding="utf-8")).encode("utf-8")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if not args.output.exists() or args.output.read_bytes() != generated:
        args.output.write_bytes(generated)
