#ifndef __WINE_IOS_IPC_H
#define __WINE_IOS_IPC_H
#include "iosdrv.h"
#define JUICE_IOS_MAGIC 0x4a554943u
#define JUICE_IOS_HELLO 1u
#define JUICE_IOS_DESKTOP 2u
#define JUICE_IOS_WINDOW 3u
#define JUICE_IOS_DESTROY 4u
#define JUICE_IOS_FRAME 5u
#define JUICE_IOS_INPUT 100u
#define JUICE_IOS_TEXT 101u
#define JUICE_IOS_KEY 102u
#define JUICE_IOS_LEFT_DOWN 1u
#define JUICE_IOS_LEFT_UP 2u
#define JUICE_IOS_RIGHT_DOWN 4u
#define JUICE_IOS_RIGHT_UP 8u
/* INPUT wheel events keep x/y as the pointer location. Vertical wheel delta is
 * carried in height; horizontal wheel delta is carried in width. Deltas use
 * Win32 mouse-wheel units, where WHEEL_DELTA (120) is one detent. */
#define JUICE_IOS_WHEEL 0x10u
#define JUICE_IOS_HWHEEL 0x20u
/* KEY messages keep the Win32 virtual key in the low 16 bits. These modifier
 * bits request an atomic modifier-down, key-down/up, modifier-up chord. Plain
 * low-16-bit KEY messages retain the original single-key tap behavior. */
#define JUICE_IOS_KEY_SHIFT   0x00010000u
#define JUICE_IOS_KEY_CONTROL 0x00020000u
#define JUICE_IOS_KEY_ALT     0x00040000u
/* x/y are Wine desktop coordinates instead of window-local coordinates. */
#define JUICE_IOS_COORDS_DESKTOP 0x40000000u
/* FRAME payload contains only the packed BGRA dirty rectangle. x/y locate the
 * rect within the full surface, width/height are the dirty dimensions, and
 * stride is the packed dirty-row stride. The first frame for every new or
 * resized surface is always sent without this flag as a full-frame baseline. */
#define JUICE_IOS_FRAME_DIRTY 0x20000000u
struct juice_ios_msg { UINT magic,type,size; UINT64 hwnd; INT x,y,width,height; UINT stride,flags; };
void ios_ipc_init(unsigned int width,unsigned int height,unsigned int dpi);
void ios_ipc_register_queue(void);
void ios_ipc_window(HWND hwnd,const RECT *rect,BOOL visible);
void ios_ipc_destroy(HWND hwnd);
void ios_ipc_present(HWND hwnd,const void *bits,unsigned int width,unsigned int height,unsigned int stride,const RECT *dirty);
BOOL ios_ipc_process_input(void);
#endif