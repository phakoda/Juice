#include "JuiceKeyChord.h"
#include <string.h>

_Static_assert(sizeof(JuiceKeyPacket) == 48, "display packet ABI changed");
_Static_assert(offsetof(JuiceKeyPacket, hwnd) == 16, "HWND alignment changed");

size_t JuiceBuildKeyChord(uint64_t hwnd, uint16_t key, uint16_t scan,
                         bool extended, unsigned modifiers,
                         JuiceKeyPacket *out, size_t capacity)
{
    if (!hwnd || !key || key > 255 || !scan || scan > 127 || modifiers > 15 || !out) return 0;
    /* Do not create ambiguous duplicate modifier-down/up pairs. */
    if (key == 0x10 || key == 0x11 || key == 0x12 || key == 0x5b || key == 0x5c ||
        (key >= 0xa0 && key <= 0xa5)) return 0;
    unsigned count = 0;
    for (unsigned bit = 1; bit <= 8; bit <<= 1) if (modifiers & bit) count++;
    size_t needed = 2 + 2 * count;
    if (capacity < needed) return 0;
    static const uint16_t keys[] = {0xa2, 0xa4, 0xa0, 0x5b};
    static const uint16_t scans[] = {0x1d, 0x38, 0x2a, 0x5b};
    memset(out, 0, needed * sizeof(*out));
    size_t position = 0;
    for (unsigned i = 0; i < 4; i++) if (modifiers & (1u << i)) {
        out[position].x = keys[i]; out[position].y = scans[i];
        out[position++].flags = 1u | (i == 3 ? 4u : 0u);
    }
    out[position].x = key; out[position].y = scan;
    out[position++].flags = 1u | (extended ? 4u : 0u);
    out[position].x = key; out[position].y = scan;
    out[position++].flags = 2u | (extended ? 4u : 0u);
    for (unsigned i = 4; i > 0; i--) if (modifiers & (1u << (i - 1))) {
        out[position].x = keys[i - 1]; out[position].y = scans[i - 1];
        out[position++].flags = 2u | (i == 4 ? 4u : 0u);
    }
    for (size_t i = 0; i < needed; i++) {
        out[i].magic = 0x4a554943u; out[i].type = 103u; out[i].hwnd = hwnd;
    }
    return position;
}
