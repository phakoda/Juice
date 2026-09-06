#include "../wine/dlls/wineios.drv/graphics_policy.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static void put32(uint8_t *out, uint32_t value)
{
    for (unsigned i = 0; i < 4; ++i) out[i] = (uint8_t)(value >> (8 * i));
}
int main(void)
{
    size_t used = 0;
    assert(!juice_readback_budget_reserve(NULL, 1));
    assert(!juice_readback_budget_reserve(&used, 0) && used == 0);
    assert(!juice_readback_budget_reserve(&used, SIZE_MAX) && used == 0);
    assert(juice_readback_budget_reserve(&used, JUICE_GRAPHICS_MAX_BYTES));
    assert(juice_readback_budget_reserve(&used, JUICE_GRAPHICS_MAX_BYTES));
    assert(used == JUICE_GRAPHICS_TOTAL_BYTES);
    assert(!juice_readback_budget_reserve(&used, 1) && used == JUICE_GRAPHICS_TOTAL_BYTES);
    used -= JUICE_GRAPHICS_MAX_BYTES; /* Failed replacement releases only its reservation. */
    assert(juice_readback_budget_reserve(&used, JUICE_GRAPHICS_MAX_BYTES));
    used = SIZE_MAX;
    assert(!juice_readback_budget_reserve(&used, 1) && used == SIZE_MAX);
    struct juice_readback_layout layout;
    assert(juice_rect_extent(INT32_MIN, INT32_MAX) == UINT32_MAX);
    assert(juice_rect_extent(INT32_MAX, INT32_MIN) == 1);
    assert(juice_rect_extent(20, 20) == 1);
    assert(juice_rect_extent(-20, 20) == 40);
    assert(!juice_readback_layout(juice_rect_extent(INT32_MIN, INT32_MAX), 1, 1, &layout));
    assert(juice_readback_layout(1920, 1080, 256, &layout));
    assert(layout.stride == 7680 && layout.bytes == 8294400);
    assert(!juice_readback_layout(1, 1, 3, &layout));
    assert(!layout.stride && !layout.bytes);
    assert(!juice_readback_layout(SIZE_MAX, 1, 256, &layout));
    assert(!juice_readback_layout(1, SIZE_MAX, 256, &layout));
    assert(!juice_readback_layout(8192, 8192, 256, &layout));
    assert(!juice_readback_layout(1, 1, (SIZE_MAX / 2) + 1, &layout));
    assert(!juice_readback_layout(0, 1, 256, &layout));
    assert(!juice_readback_layout(1, 1, 256, NULL));
    assert(juice_readback_layout(8192, 2048, 256, &layout));
    assert(layout.bytes == 64u * 1024u * 1024u);

    uint8_t pixels[512], saved[512];
    for (unsigned value = 0; value < 256; ++value) {
        memset(pixels, 0xac, sizeof(pixels));
        pixels[0] = (uint8_t)value; pixels[1] = 47; pixels[2] = 29; pixels[3] = 193;
        pixels[256] = 71; pixels[257] = 255; pixels[258] = (uint8_t)value; pixels[259] = 17;
        assert(juice_readback_to_bgra(pixels, sizeof(pixels), 1, 2, 256, JUICE_READBACK_RGBA8));
        assert(pixels[0] == 29 && pixels[1] == 47 && pixels[2] == value && pixels[3] == 193);
        assert(pixels[256] == value && pixels[258] == 71 && pixels[259] == 17);
        for (unsigned i = 4; i < 256; ++i) assert(!pixels[i] && !pixels[i + 256]);
    }
    for (unsigned value = 0; value < 1024; ++value)
    for (unsigned alpha = 0; alpha < 4; ++alpha) {
        unsigned rounded = (unsigned)((double)value * 255.0 / 1023.0 + 0.5);
        put32(pixels, value | 512u << 10 | 1023u << 20 | alpha << 30);
        assert(juice_readback_to_bgra(pixels, 4, 1, 1, 4, JUICE_READBACK_RGB10A2));
        assert(pixels[0] == 255 && pixels[1] == 128 && pixels[2] == rounded && pixels[3] == alpha * 85);
        put32(pixels, value | 512u << 10 | 1023u << 20 | alpha << 30);
        assert(juice_readback_to_bgra(pixels, 4, 1, 1, 4, JUICE_READBACK_BGR10A2));
        assert(pixels[0] == rounded && pixels[1] == 128 && pixels[2] == 255 && pixels[3] == alpha * 85);
    }
    memset(pixels, 0x5a, sizeof(pixels)); memcpy(saved, pixels, sizeof(pixels));
    assert(!juice_readback_to_bgra(pixels, 3, 1, 1, 4, JUICE_READBACK_RGBA8));
    assert(!juice_readback_to_bgra(pixels, sizeof(pixels), 1, 2, SIZE_MAX, JUICE_READBACK_BGRA8));
    assert(!juice_readback_to_bgra(pixels, sizeof(pixels), 1, 1, 4, JUICE_READBACK_UNSUPPORTED));
    assert(!juice_readback_to_bgra(pixels, sizeof(pixels), 1, 1, 4, (enum juice_readback_format)-1));
    assert(!memcmp(pixels, saved, sizeof(pixels)));
    assert(juice_readback_to_bgra(pixels, sizeof(pixels), 32, 4, 128, JUICE_READBACK_BGRA8));
    assert(!memcmp(pixels, saved, sizeof(pixels)));

    /* Vary width, row padding and allocation alignment; ASan checks both ends. */
    for (size_t width = 1; width <= 1024; ++width) {
        assert(juice_readback_layout(width, 3, 256, &layout));
        uint8_t *bytes = malloc(layout.bytes + 2);
        assert(bytes); memset(bytes, 0xa7, layout.bytes + 2);
        assert(juice_readback_to_bgra(bytes + 1, layout.bytes, width, 3, layout.stride, JUICE_READBACK_RGBA8));
        assert(bytes[0] == 0xa7 && bytes[layout.bytes + 1] == 0xa7);
        free(bytes);
    }
    puts("JUICE_GRAPHICS_POLICY_OK rgba_values=256 packed10_values=1024 alpha_values=4 layouts=1024 aggregate_budget=pass");
}
