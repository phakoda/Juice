#include "JuiceUTF8Stream.h"
#include <string.h>
/* Positive scalar length; 0 incomplete; -1 malformed. */
static int scalar(const uint8_t *s, size_t n)
{
    if (!n) return 0;
    uint8_t a = s[0];
    if (a < 0x80) return 1;
    int need = a >= 0xc2 && a <= 0xdf ? 2 :
               a >= 0xe0 && a <= 0xef ? 3 :
               a >= 0xf0 && a <= 0xf4 ? 4 : -1;
    if (need < 0) return -1;
    for (int i = 1; i < need && (size_t)i < n; i++) {
        if ((s[i] & 0xc0) != 0x80) return -1;
        if (i == 1 && ((a == 0xe0 && s[i] < 0xa0) ||
                       (a == 0xed && s[i] >= 0xa0) ||
                       (a == 0xf0 && s[i] < 0x90) ||
                       (a == 0xf4 && s[i] >= 0x90))) return -1;
    }
    return n < (size_t)need ? 0 : need;
}
size_t JuiceUTF8CompletePrefix(const uint8_t *s, size_t n)
{
    if (!s) return 0;
    size_t start = n > 3 ? n - 3 : 0;
    for (size_t i = start; i < n; i++)
        if (scalar(s + i, n - i) == 0) return i;
    return n;
}
size_t JuiceUTF8Sanitize(const uint8_t *s, size_t n, uint8_t *out,
                        size_t cap, size_t *consumed)
{
    size_t i = 0, used = 0;
    if (consumed) *consumed = 0;
    if ((!s && n) || (!out && cap)) return 0;
    while (i < n) {
        int width = scalar(s + i, n - i);
        size_t emitted = width > 0 ? (size_t)width : 3;
        if (emitted > cap - used) break;
        if (width > 0) memcpy(out + used, s + i, emitted);
        else { out[used] = 0xef; out[used + 1] = 0xbf; out[used + 2] = 0xbd; }
        used += emitted;
        i += width > 0 ? (size_t)width : 1;
    }
    if (consumed) *consumed = i;
    return used;
}
