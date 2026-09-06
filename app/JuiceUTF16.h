#ifndef JUICE_UTF16_H
#define JUICE_UTF16_H
#include <stddef.h>
#include <stdint.h>

/* Return a bounded, even UTF-16LE prefix without splitting a surrogate pair.
 * Zero denotes an invalid buffer/limit (including a limit too small for the
 * first pair). This helper does not replace full Unicode validation. */
static inline size_t JuiceUTF16ChunkLength(const void *data, size_t remaining,
                                           size_t limit)
{
    if (!data || !remaining || (remaining & 1)) return 0;
    size_t length = (remaining < limit ? remaining : limit) & ~(size_t)1;
    if (!length) return 0;
    if (length < remaining)
    {
        const uint8_t *bytes = data;
        uint16_t last = bytes[length - 2] | ((uint16_t)bytes[length - 1] << 8);
        uint16_t next = bytes[length] | ((uint16_t)bytes[length + 1] << 8);
        if (last >= 0xd800 && last <= 0xdbff && next >= 0xdc00 && next <= 0xdfff)
            length -= 2;
    }
    return length;
}
#endif
