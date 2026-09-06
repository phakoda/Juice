#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "JuiceUTF8Stream.h"
int main(void)
{
    alarm(30);
    const uint8_t text[] = {'A',0xc3,0xa9,0xe2,0x82,0xac,0xf0,0x9f,0x9a,0x80,'Z'};
    for (size_t split = 0; split <= sizeof(text); split++) {
        uint8_t output[100]; size_t used, total = 0;
        size_t n = JuiceUTF8CompletePrefix(text, split);
        total += JuiceUTF8Sanitize(text, n, output, sizeof(output), &used); assert(used == n);
        total += JuiceUTF8Sanitize(text + n, sizeof(text) - n, output + total, sizeof(output) - total, &used);
        assert(total == sizeof(text) && !memcmp(output, text, sizeof(text)));
    }
    uint8_t out[100]; size_t used;
    uint8_t invalid[] = {0xc0, 0xaf, 0xed, 0xa0, 0x80, 0xf4, 0x90, 0x80, 0x80, 0xff};
    assert(JuiceUTF8Sanitize(invalid, sizeof(invalid), out, sizeof(out), &used) == 30 && used == sizeof(invalid));
    assert(JuiceUTF8Sanitize(invalid, sizeof(invalid), out, 2, &used) == 0 && used == 0);
    uint8_t incomplete[] = {0xf0, 0x9f, 0x9a};
    assert(JuiceUTF8CompletePrefix(incomplete, 3) == 0);
    assert(JuiceUTF8Sanitize(incomplete, 3, out, sizeof(out), &used) == 9 && used == 3);
    assert(JuiceUTF8Sanitize(NULL, 0, NULL, 0, &used) == 0 && used == 0);
    for (uint32_t cp = 0; cp <= 0x10ffff; cp++) {
        if (cp >= 0xd800 && cp <= 0xdfff) continue;
        uint8_t b[4]; size_t n;
        if (cp < 0x80) { b[0] = (uint8_t)cp; n = 1; }
        else if (cp < 0x800) { b[0] = 0xc0 | (cp >> 6); b[1] = 0x80 | (cp & 63); n = 2; }
        else if (cp < 0x10000) { b[0] = 0xe0 | (cp >> 12); b[1] = 0x80 | ((cp >> 6) & 63); b[2] = 0x80 | (cp & 63); n = 3; }
        else { b[0] = 0xf0 | (cp >> 18); b[1] = 0x80 | ((cp >> 12) & 63); b[2] = 0x80 | ((cp >> 6) & 63); b[3] = 0x80 | (cp & 63); n = 4; }
        assert(JuiceUTF8Sanitize(b, n, out, sizeof(out), &used) == n && used == n && !memcmp(b, out, n));
        for (size_t j = 1; j < n; j++) assert(JuiceUTF8CompletePrefix(b, j) == 0);
        assert(JuiceUTF8CompletePrefix(b, n) == n);
    }
    puts("UTF8_STREAM_OK unicode_scalars=1112064 all_scalar_split_boundaries=pass");
    return 0;
}
