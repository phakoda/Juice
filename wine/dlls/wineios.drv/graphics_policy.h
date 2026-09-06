/* Software transport policy for Metal surfaces. LGPL-2.1-or-later. */
#ifndef JUICE_GRAPHICS_POLICY_H
#define JUICE_GRAPHICS_POLICY_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* Match the UIKit receiver's per-frame limits before asking Metal to allocate. */
#define JUICE_GRAPHICS_MAX_DIMENSION 8192u
#define JUICE_GRAPHICS_MAX_PIXELS (4096u * 4096u)
#define JUICE_GRAPHICS_MAX_BYTES (128u * 1024u * 1024u)

enum juice_readback_format {
    JUICE_READBACK_UNSUPPORTED,
    JUICE_READBACK_BGRA8,
    JUICE_READBACK_RGBA8,
    JUICE_READBACK_RGB10A2,
    JUICE_READBACK_BGR10A2
};
struct juice_readback_layout { size_t stride, bytes; };

/* Win32 rectangle subtraction must widen before subtracting; minimized or
 * empty surfaces preserve the driver's historical one-pixel minimum. */
static inline size_t juice_rect_extent(int32_t begin, int32_t end)
{
    int64_t extent = (int64_t)end - begin;
    return extent > 0 ? (size_t)extent : 1;
}

static inline bool juice_readback_layout(size_t width, size_t height, size_t alignment,
                                         struct juice_readback_layout *out)
{
    size_t row, stride;
    if (!out) return false;
    *out = (struct juice_readback_layout){0, 0};
    if (!width || !height || width > JUICE_GRAPHICS_MAX_DIMENSION || height > JUICE_GRAPHICS_MAX_DIMENSION ||
        width > JUICE_GRAPHICS_MAX_PIXELS / height || !alignment || (alignment & (alignment - 1))) return false;
    row = width * 4u;
    if (alignment - 1 > SIZE_MAX - row) return false;
    stride = (row + alignment - 1) & ~(alignment - 1);
    if (stride > JUICE_GRAPHICS_MAX_BYTES / height) return false;
    out->stride = stride; out->bytes = stride * height;
    return true;
}

static inline uint8_t juice_unorm10_to_unorm8(uint32_t value)
{
    return (uint8_t)((value * 255u + 511u) / 1023u);
}

/* In-place conversion after GPU completion. All supported formats use 4 B/px.
 * This is SDR quantization/channel ordering, NOT HDR tone mapping. Unsupported
 * formats fail without touching the buffer. Padding is never sent uninitialized.
 * A completed frame must be blitted again before calling this a second time. */
static inline bool juice_readback_to_bgra(void *data, size_t capacity, size_t width,
                                        size_t height, size_t stride, enum juice_readback_format format)
{
    struct juice_readback_layout tight;
    if (!data || format < JUICE_READBACK_BGRA8 || format > JUICE_READBACK_BGR10A2 ||
        !juice_readback_layout(width, height, 1, &tight) || stride < tight.stride ||
        stride > JUICE_GRAPHICS_MAX_BYTES / height || stride > capacity / height) return false;
    for (size_t y = 0; y < height; ++y) {
        uint8_t *row = (uint8_t *)data + y * stride;
        if (format == JUICE_READBACK_RGBA8) {
            for (size_t x = 0; x < width; ++x) {
                uint8_t r = row[x * 4];
                row[x * 4] = row[x * 4 + 2]; row[x * 4 + 2] = r;
            }
        } else if (format == JUICE_READBACK_RGB10A2 || format == JUICE_READBACK_BGR10A2) {
            for (size_t x = 0; x < width; ++x) {
                uint8_t *pixel = row + x * 4;
                uint32_t packed = (uint32_t)pixel[0] | (uint32_t)pixel[1] << 8 |
                                  (uint32_t)pixel[2] << 16 | (uint32_t)pixel[3] << 24;
                uint8_t low = juice_unorm10_to_unorm8(packed & 1023u);
                uint8_t high = juice_unorm10_to_unorm8((packed >> 20) & 1023u);
                pixel[0] = format == JUICE_READBACK_RGB10A2 ? high : low;
                pixel[1] = juice_unorm10_to_unorm8((packed >> 10) & 1023u);
                pixel[2] = format == JUICE_READBACK_RGB10A2 ? low : high;
                pixel[3] = (uint8_t)((packed >> 30) * 85u);
            }
        }
        memset(row + tight.stride, 0, stride - tight.stride);
    }
    return true;
}
#endif
