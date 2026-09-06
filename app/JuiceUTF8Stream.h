#ifndef JUICE_UTF8_STREAM_H
#define JUICE_UTF8_STREAM_H
#include <stddef.h>
#include <stdint.h>
/* Largest prefix without an incomplete, potentially valid trailing scalar. */
size_t JuiceUTF8CompletePrefix(const uint8_t *bytes, size_t length);
/* Replace malformed bytes with U+FFFD, without appending NUL. Buffers must not
 * overlap. consumed reports partial progress if destination capacity is low. */
size_t JuiceUTF8Sanitize(const uint8_t *source, size_t length,
                        uint8_t *destination, size_t capacity, size_t *consumed);
#endif
