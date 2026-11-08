# PPA

## General info

Hardware reference for ESP32-P4 **silicon revision v1.3**, with ESP-IDF 5.5.6 driver limits. These capabilities are not additional TabOS `gfx` APIs. Support for v3.x is planned for future TabOS versions.

PPA has two engines: scale/rotate/mirror (SRM), and BLEND, which also performs fills. Operations target rectangular regions of memory-backed pictures. [Datasheet §4.2.1.3](https://documentation.espressif.com/esp32-p4-chip-revision-v1.3_datasheet_en.html)

Both engines support input RGB/byte swaps and alpha preservation, replacement, scaling (1/256 resolution), or inversion. RGB inputs default to opaque. Byte swaps apply only to ARGB8888/RGB565 input. [Alpha/formats](https://github.com/espressif/esp-idf/blob/v5.5.6/components/hal/include/hal/ppa_types.h), [operation configuration](https://docs.espressif.com/projects/esp-idf/en/v5.5.6/esp32p4/api-reference/peripherals/ppa.html)

## SRM

Scale, rotate, mirror, and convert between **ARGB8888, RGB888, RGB565, and YUV420**. Scaling, rotation, and mirroring can be combined in one operation. [v1.3 datasheet §4.2.1.3](https://documentation.espressif.com/esp32-p4-chip-revision-v1.3_datasheet_en.html)

### Scaling

SRM uses bilinear scaling. For each axis, ESP-IDF 5.5.6 accepts `1/16 <= scale < 256` and truncates to **1/16 steps**:

| Scaling limit | Value |
| --- | --- |
| Minimum | **0.0625×** (shrink by 16) |
| Maximum representable | **255.9375×** (`255 + 15/16`) |
| Precision | **0.0625×**; horizontal and vertical factors are independent |

The [datasheet](https://documentation.espressif.com/esp32-p4-chip-revision-v1.3_datasheet_en.html) states four integer/eight fractional bits while driver takes eight integer/four fractional bits. This discrepancy remains unresolved; the maximum above has not been verified on hardware.

### Rotation

Set `rotation_angle` to one of these enum constants; it does not accept an arbitrary angle in degrees:

| Constant | Rotation |
| --- | --- |
| `PPA_SRM_ROTATION_ANGLE_0` | None |
| `PPA_SRM_ROTATION_ANGLE_90` | 90° counterclockwise |
| `PPA_SRM_ROTATION_ANGLE_180` | 180° |
| `PPA_SRM_ROTATION_ANGLE_270` | 270° counterclockwise (90° clockwise) |

90°/270° rotations swap the scaled region's width and height. Arbitrary angles require software rendering or pre-rotated assets. [Rotation enum](https://github.com/espressif/esp-idf/blob/v5.5.6/components/hal/include/hal/ppa_types.h), [output sizing](https://github.com/espressif/esp-idf/blob/v5.5.6/components/esp_driver_ppa/src/ppa_srm.c)

### Mirroring

Set `mirror_x = true` for a horizontal (left/right) flip and `mirror_y = true` for a vertical (top/bottom) flip. The flags are independent: enable either, both, or neither. Mirroring can be combined with scaling and rotation in the same SRM transaction. [SRM configuration](https://docs.espressif.com/projects/esp-idf/en/v5.5.6/esp32p4/api-reference/peripherals/ppa.html#_CPPv421ppa_srm_oper_config_t)

### Alpha replacement

`PPA_ALPHA_FIX_VALUE` replaces every processed pixel's alpha with `alpha_fix_val` (0 = transparent, 255 = opaque), including pixels that were previously transparent.

To fade a sprite while preserving its transparency pattern, use `PPA_ALPHA_SCALE` and `alpha_scale_ratio` instead; replacement makes transparent edges visible. 

SRM writes pixels without compositing onto a background; use BLEND afterward. RGB565/RGB888 output cannot retain alpha. [SRM configuration](https://docs.espressif.com/projects/esp-idf/en/v5.5.6/esp32p4/api-reference/peripherals/ppa.html#_CPPv421ppa_srm_oper_config_t)

## BLEND

Alpha-composite two equally sized foreground/background regions, or fill a rectangle with a constant color.

| Port | v1.3 hardware formats |
| --- | --- |
| Foreground input | ARGB8888, RGB888, RGB565, L4, L8, A4, A8 |
| Background input | ARGB8888, RGB888, RGB565, L4, L8 |
| Output / fill | ARGB8888, RGB888, RGB565 |

L4/L8 hardware support is not exposed by the project's driver; see Driver constraints. Port distinctions follow the [v1 register definitions](https://github.com/espressif/esp-idf/blob/v5.5.6/components/soc/esp32p4/register/hw_ver1/soc/ppa_struct.h).

### Alpha masks and color keys

A4/A8 foreground pixels supply 4-bit/8-bit alpha with one constant RGB color set by `fg_fix_rgb_val` [Mask configuration](https://docs.espressif.com/projects/esp-idf/en/v5.5.6/esp32p4/api-reference/peripherals/ppa.html)

Independent foreground/background color-key ranges provide binary transparency. For an RGB565 sprite, enable `fg_ck_en` and set equal `fg_ck_rgb_low_thres`/`fg_ck_rgb_high_thres` in RGB888 to select one transparent color. Disable background keying to preserve the background at matching foreground pixels. [BLEND configuration](https://docs.espressif.com/projects/esp-idf/en/v5.5.6/esp32p4/api-reference/peripherals/ppa.html#blend)

### L4/L8 indexed colors

Each pixel stores a palette index, which BLEND expands through a color lookup table (CLUT) into an **ARGB8888 color, including alpha**. Foreground and background have separate CLUTs. These are color indices, not grayscale intensities. [Hardware CLUT access](https://github.com/espressif/esp-idf/blob/v5.5.6/components/hal/esp32p4/include/hal/ppa_ll.h)

| Format | Pixel storage | Addressable palette entries |
| --- | --- | --- |
| L4 | 4 bits/pixel; two indices per byte | 16 (indices 0–15) |
| L8 | 8 bits/pixel; one index per byte | 256 (indices 0–255) |

**CLUT supports 8-bit alpha per palette entry**. Every pixel referencing an entry shares its color and alpha; blend alpha replacement/scaling can modify that alpha. Index 0 is not automatically transparent. Each distinct color/alpha combination consumes an entry. Changing a palette entry recolors all pixels using it without rewriting their indices. [Indexed-color semantics](https://docs.espressif.com/projects/esp-idf/en/latest/esp32p4/api-reference/peripherals/ppa.html#color-look-up-table-clut)

Indexed formats are **BLEND inputs only**; SRM cannot directly scale/rotate them, and PPA cannot output indexed images. Expand to RGB/ARGB first for SRM, using ARGB8888 to retain palette alpha.

## Driver constraints

- **ESP-IDF 5.5.6 leaves L4/L8/CLUT support disabled.** Using it requires driver work or an SDK upgrade; newer development documentation exposes `ppa_set_color_lookup_table()`. [5.5.6 formats](https://github.com/espressif/esp-idf/blob/v5.5.6/components/hal/include/hal/ppa_types.h), [newer CLUT API](https://docs.espressif.com/projects/esp-idf/en/latest/esp32p4/api-reference/peripherals/ppa.html#color-look-up-table-clut)
- YUV444 SRM input uses 2D-DMA conversion to RGB888, not native PPA YUV444 hardware. [Driver formats](https://github.com/espressif/esp-idf/blob/v5.5.6/components/hal/include/hal/ppa_types.h)
- SRM requires separate input/output buffers; BLEND permits output to alias an input. Regions must fit their pictures.
- YUV420 dimensions and offsets must be even; A4 region width and horizontal offset must be even.
- Output address and allocated size require cache-line alignment. Encrypted external memory needs 16-byte row/block alignment; SRM cannot use external-memory buffers with flash encryption enabled.
- Blocking or queued asynchronous execution is supported; completion callbacks run in interrupt context. PSRAM bandwidth shared with other peripherals limits throughput. [ESP-IDF 5.5.6 guide](https://docs.espressif.com/projects/esp-idf/en/v5.5.6/esp32p4/api-reference/peripherals/ppa.html)

## v3.x changes

Planned for future TabOS versions:

| Area | Change from v1.3 |
| --- | --- |
| SRM formats | Adds YUV422 and GRAY input/output. Grayscale support does not add an SRM tint control. |
| SRM internal blocks | Expands from 16×16 to 32×32; these are not maximum sprite/image dimensions. |
| BLEND formats | Adds YUV422/YUV420/GRAY background input and output; foreground formats stay unchanged. |
| Indexed SRM | No change: L4/L8 still require expansion to RGB/ARGB before SRM. |

[Migration guide §1.21](https://documentation.espressif.com/esp32-p4-chip-revision-v3.x_user_guide_en.pdf), [current datasheet §4.2.1.3](https://documentation.espressif.com/esp32-p4_datasheet_en.html), [v3 register definitions](https://github.com/espressif/esp-idf/blob/v5.5.6/components/soc/esp32p4/register/hw_ver3/soc/ppa_struct.h), [revision-dependent HAL](https://github.com/espressif/esp-idf/blob/v5.5.6/components/hal/esp32p4/include/hal/ppa_ll.h)
