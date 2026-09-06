/* Portable wineios readback policy. LGPL-2.1-or-later. */
#ifndef WINEIOS_GRAPHICS_LAYOUT_H
#define WINEIOS_GRAPHICS_LAYOUT_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define IOS_GRAPHICS_MAX_DIMENSION 8192u
#define IOS_GRAPHICS_MAX_PIXELS (4096u * 4096u)
#define IOS_GRAPHICS_MAX_BYTES (128u * 1024u * 1024u)
#define IOS_GRAPHICS_TOTAL_BYTES (256u * 1024u * 1024u)

enum ios_pixel_format {
    IOS_PIXEL_UNSUPPORTED, IOS_PIXEL_BGRA8, IOS_PIXEL_RGBA8,
    IOS_PIXEL_RGB10A2, IOS_PIXEL_BGR10A2
};
struct ios_graphics_layout { size_t stride, size; };

/* No wraparound, allocation, or outputs with partially validated geometry. */
static inline bool ios_graphics_layout(uint64_t width, uint64_t height,
                                       size_t alignment, struct ios_graphics_layout *out)
{
    if (!out) return false;
    *out = (struct ios_graphics_layout){0};
    if (!width || !height || width > IOS_GRAPHICS_MAX_DIMENSION ||
        height > IOS_GRAPHICS_MAX_DIMENSION || width * height > IOS_GRAPHICS_MAX_PIXELS ||
        !alignment || (alignment & (alignment - 1)) || alignment > 4096) return false;
    size_t row = (size_t)width * 4;
    size_t stride = (row + alignment - 1) & ~(alignment - 1);
    if (stride > IOS_GRAPHICS_MAX_BYTES / height) return false;
    out->stride = stride;
    out->size = stride * (size_t)height;
    return true;
}

static inline bool ios_graphics_budget_reserve(size_t *used, size_t bytes)
{
    if (!used || !bytes || bytes > IOS_GRAPHICS_MAX_BYTES ||
        *used > IOS_GRAPHICS_TOTAL_BYTES || bytes > IOS_GRAPHICS_TOTAL_BYTES - *used) return false;
    *used += bytes;
    return true;
}

/* Decode little-endian words explicitly, including on a big-endian test host. */
static inline uint32_t ios_pixel_u32(const unsigned char *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static inline unsigned char ios_unorm10_to_8(uint32_t channel)
{
    return (unsigned char)((channel * 255u + 511u) / 1023u);
}

/* The IPC sink is SDR BGRA8, not HDR. Quantize 10-bit UNORM with rounding;
 * preserve stored sRGB bytes (a buffer blit does not apply texture sampling).
 * FP16/XR/compressed/depth formats are deliberately not reinterpreted as BGRA.
 * Input/output share a buffer; compact toward its beginning only. A complete
 * source pixel is loaded before writing it, and no unread row is overwritten. */
static inline bool ios_graphics_pack_bgra(void *buffer, size_t capacity,
    uint32_t width, uint32_t height, size_t source_stride, enum ios_pixel_format format)
{
    struct ios_graphics_layout packed;
    if (!ios_graphics_layout(width, height, 1, &packed) || !buffer ||
        format < IOS_PIXEL_BGRA8 || format > IOS_PIXEL_BGR10A2 ||
        source_stride < packed.stride || source_stride > IOS_GRAPHICS_MAX_BYTES / height ||
        source_stride * height > capacity) return false;
    unsigned char *bytes = buffer;
    for (uint32_t y = 0; y < height; ++y) {
        const unsigned char *src = bytes + (size_t)y * source_stride;
        unsigned char *dst = bytes + (size_t)y * packed.stride;
        if (format == IOS_PIXEL_BGRA8) {
            if (src != dst) memmove(dst, src, packed.stride);
            continue;
        }
        for (uint32_t x = 0; x < width; ++x, src += 4, dst += 4) {
            uint32_t pixel = ios_pixel_u32(src);
            if (format == IOS_PIXEL_RGBA8) {
                dst[0] = (unsigned char)(pixel >> 16);
                dst[1] = (unsigned char)(pixel >> 8);
                dst[2] = (unsigned char)pixel;
                dst[3] = (unsigned char)(pixel >> 24);
            } else {
                unsigned char low = ios_unorm10_to_8(pixel & 1023u);
                unsigned char green = ios_unorm10_to_8((pixel >> 10) & 1023u);
                unsigned char high = ios_unorm10_to_8((pixel >> 20) & 1023u);
                dst[0] = format == IOS_PIXEL_BGR10A2 ? low : high;
                dst[1] = green;
                dst[2] = format == IOS_PIXEL_BGR10A2 ? high : low;
                dst[3] = (unsigned char)((pixel >> 30) * 85u);
            }
        }
    }
    return true;
}
#endif
