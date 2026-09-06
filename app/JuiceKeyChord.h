#ifndef JUICE_KEY_CHORD_H
#define JUICE_KEY_CHORD_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define JUICE_CHORD_CONTROL 1u
#define JUICE_CHORD_ALT 2u
#define JUICE_CHORD_SHIFT 4u
#define JUICE_CHORD_WINDOWS 8u
#define JUICE_CHORD_MAX_MESSAGES 10u
/* Exact native display-channel ABI. Every padding byte is initialized. */
typedef struct {
    uint32_t magic, type, size;
    uint64_t hwnd;
    int32_t x, y, width, height;
    uint32_t stride, flags;
} JuiceKeyPacket;
/* Returns zero without touching output on invalid input/insufficient capacity.
 * A chord is balanced in one batch: modifiers down, key down/up, reverse ups. */
size_t JuiceBuildKeyChord(uint64_t hwnd, uint16_t key, uint16_t scan,
                         bool extended, unsigned modifiers,
                         JuiceKeyPacket *output, size_t capacity);
#ifdef __OBJC__
#import <Foundation/Foundation.h>
/* Main queue only; atomically queues the entire chord to one selected live HWND.
 * YES means accepted by the writer, not acknowledged by the Windows program. */
BOOL JuiceQueueKeyChord(id owner, uint16_t key, uint16_t scan, BOOL extended, unsigned modifiers);
BOOL JuiceSendText(id owner, NSString *text, NSString *source);
#endif
#endif
