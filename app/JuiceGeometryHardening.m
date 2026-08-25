#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

/* Keep geometry limits comfortably above real iPad/desktop use while bounding
   compositor memory. 16M pixels is 64 MiB at BGRA8 before UIKit overhead and
   includes 4K (8.3M pixels) with substantial headroom. */
#define JUICE_MAX_DESKTOP_DIMENSION 8192.0
#define JUICE_MAX_DESKTOP_PIXELS (4096.0 * 4096.0)
#define JUICE_MAX_WINDOW_DIMENSION 8192
#define JUICE_MAX_WINDOW_PIXELS (4096LL * 4096LL)
#define JUICE_MAX_WINDOW_ORIGIN 131072

typedef struct
{
    uint32_t magic, type, size;
    uint64_t hwnd;
    int32_t x, y, width, height;
    uint32_t stride, flags;
} JuiceGeometryMsg;

static void (*JuiceOriginalSetDesktopSize)(id, SEL, CGSize);
static void (*JuiceOriginalUpdateWindow)(id, SEL, JuiceGeometryMsg, int);

static void JuiceGeometryAppend(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static BOOL JuiceDesktopSizeIsSafe(CGSize size)
{
    if (!isfinite(size.width) || !isfinite(size.height) ||
        size.width < 1.0 || size.height < 1.0 ||
        size.width > JUICE_MAX_DESKTOP_DIMENSION ||
        size.height > JUICE_MAX_DESKTOP_DIMENSION)
        return NO;
    return size.width * size.height <= JUICE_MAX_DESKTOP_PIXELS;
}

static BOOL JuiceWindowGeometryIsSafe(JuiceGeometryMsg message)
{
    /* Visibility-only notifications are allowed to omit geometry. */
    if (message.width <= 0 && message.height <= 0) return YES;
    if (message.width <= 0 || message.height <= 0) return NO;
    if (message.width > JUICE_MAX_WINDOW_DIMENSION ||
        message.height > JUICE_MAX_WINDOW_DIMENSION)
        return NO;
    if ((int64_t)message.width * message.height > JUICE_MAX_WINDOW_PIXELS)
        return NO;
    if (message.x < -JUICE_MAX_WINDOW_ORIGIN || message.x > JUICE_MAX_WINDOW_ORIGIN ||
        message.y < -JUICE_MAX_WINDOW_ORIGIN || message.y > JUICE_MAX_WINDOW_ORIGIN)
        return NO;
    return YES;
}

static void JuiceSafeSetDesktopSize(id self, SEL _cmd, CGSize size)
{
    if (!JuiceDesktopSizeIsSafe(size))
    {
        JuiceGeometryAppend(self, [NSString stringWithFormat:
            @"DISPLAY_GEOMETRY_REJECTED kind=desktop size=%.0fx%.0f max_pixels=%.0f\n",
            size.width, size.height, JUICE_MAX_DESKTOP_PIXELS]);
        return;
    }
    if (JuiceOriginalSetDesktopSize) JuiceOriginalSetDesktopSize(self, _cmd, size);
}

static void JuiceSafeUpdateWindow(id self, SEL _cmd, JuiceGeometryMsg message, int fd)
{
    if (!JuiceWindowGeometryIsSafe(message))
    {
        JuiceGeometryAppend(self, [NSString stringWithFormat:
            @"DISPLAY_GEOMETRY_REJECTED kind=window fd=%d hwnd=0x%llx rect=%d,%d %dx%d flags=%u\n",
            fd, (unsigned long long)message.hwnd, message.x, message.y,
            message.width, message.height, message.flags]);
        return;
    }
    if (JuiceOriginalUpdateWindow) JuiceOriginalUpdateWindow(self, _cmd, message, fd);
}

__attribute__((constructor))
static void JuiceInstallGeometryHardening(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;

    SEL desktopSelector = NSSelectorFromString(@"setWineDesktopSize:");
    Method desktop = class_getInstanceMethod(cls, desktopSelector);
    if (desktop)
        JuiceOriginalSetDesktopSize = (void (*)(id, SEL, CGSize))
            method_setImplementation(desktop, (IMP)JuiceSafeSetDesktopSize);

    SEL windowSelector = NSSelectorFromString(@"updateWindowMessage:client:");
    Method window = class_getInstanceMethod(cls, windowSelector);
    if (window)
        JuiceOriginalUpdateWindow = (void (*)(id, SEL, JuiceGeometryMsg, int))
            method_setImplementation(window, (IMP)JuiceSafeUpdateWindow);
}
