/* Juice-original code, MIT. Bounded framing, not a permission check. */
#ifndef JUICE_JIT_ACK_H
#define JUICE_JIT_ACK_H
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

typedef struct {
    char expected[128];
    size_t length, matched;
    bool discarded, carriageReturn;
} JuiceJITAck;

/* expected is the exact launch-owned marker WITHOUT a newline. */
static inline bool JuiceJITAckInit(JuiceJITAck *state, const void *expected, size_t length)
{
    if (!state) return false;
    memset(state, 0, sizeof(*state));
    if (!expected || !length || length >= sizeof(state->expected)) return false;
    const unsigned char *bytes = expected;
    for (size_t i = 0; i < length; ++i)
        if (bytes[i] < 0x20 || bytes[i] > 0x7e) return false;
    memcpy(state->expected, expected, length);
    state->length = length;
    return true;
}

/* Chunk boundaries are not line boundaries. Mismatches, NULs, and arbitrarily
 * long lines are discarded through their next LF, using constant memory.
 * Accept exactly one complete LF or CRLF-terminated marker line; prefixes,
 * suffixes and unterminated markers never count. Caller serializes by session. */
static inline bool JuiceJITAckFeed(JuiceJITAck *state, const void *data, size_t length)
{
    if (!state || !state->length || state->length >= sizeof(state->expected)) return false;
    if (!data && length) { state->discarded = true; return false; }
    const unsigned char *bytes = data;
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = bytes[i];
        if (c == '\n') {
            bool complete = !state->discarded && state->matched == state->length;
            state->matched = 0;
            state->discarded = state->carriageReturn = false;
            if (complete) return true;
        } else if (!state->discarded) {
            if (c == '\r' && state->matched == state->length && !state->carriageReturn)
                state->carriageReturn = true;
            else if (!state->carriageReturn && state->matched < state->length &&
                     c == (unsigned char)state->expected[state->matched])
                ++state->matched;
            else state->discarded = true;
        }
    }
    return false;
}
#endif
