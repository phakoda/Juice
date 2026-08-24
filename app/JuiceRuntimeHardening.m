#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <signal.h>
#import <sys/resource.h>
#import <sys/types.h>

#define JUICE_FRAME_DIRTY 0x20000000u

typedef struct
{
    uint32_t magic, type, size;
    uint64_t hwnd;
    int32_t x, y, width, height;
    uint32_t stride, flags;
} JuiceRuntimeMsg;

@interface JuiceRuntimeFramebuffer : NSObject
@property(nonatomic,strong) NSMutableData *bytes;
@property(nonatomic) int32_t width;
@property(nonatomic) int32_t height;
@property(nonatomic) uint32_t stride;
@property(nonatomic) int clientFD;
@end
@implementation JuiceRuntimeFramebuffer
@end

/*
 * Host-process reliability fixes that are independent of Wine itself.
 *
 * Juice uses Unix sockets and pipes heavily.  On Darwin, writing to a peer
 * which has already disconnected can raise SIGPIPE and terminate the entire
 * UIKit host before write(2) has a chance to return EPIPE.  Wine clients can
 * disconnect at any point during startup/shutdown, so ignoring SIGPIPE is the
 * correct process-wide policy for the host; individual writes still receive
 * EPIPE and existing error handling can close the dead connection.
 *
 * The display/control host can also legitimately have many descriptors open
 * when Wine is starting multiple processes.  Raise the soft descriptor limit
 * toward 1024 when the platform permits it, without ever exceeding the hard
 * limit or treating a denied setrlimit as fatal.
 *
 * The Wine driver can send packed dirty rectangles after one full framebuffer
 * baseline.  main.m intentionally keeps the original, simple frame reader;
 * this hook expands those partial updates back into a stable full framebuffer
 * before the existing UIImage/compositor path sees them.  This preserves the
 * UI code while cutting the expensive cross-process transport for small GDI
 * updates by orders of magnitude.
 */

static IMP JuiceOriginalViewDidLoad;
static void (*JuiceOriginalPresentFrame)(id, SEL, JuiceRuntimeMsg, NSData *, int, pid_t, BOOL);
static void (*JuiceOriginalDestroyWindow)(id, SEL, uint64_t);
static void (*JuiceOriginalRemoveClientWindows)(id, SEL, int);
static char JuiceRuntimeFramebuffersKey;

static void JuiceRuntimeAppend(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static NSMutableDictionary<NSNumber *, JuiceRuntimeFramebuffer *> *JuiceFramebuffers(id self)
{
    NSMutableDictionary *frames = objc_getAssociatedObject(self, &JuiceRuntimeFramebuffersKey);
    if (!frames)
    {
        frames = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &JuiceRuntimeFramebuffersKey, frames,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return frames;
}

static void JuiceRaiseFileDescriptorLimit(id self)
{
    struct rlimit before = {0};
    if (getrlimit(RLIMIT_NOFILE, &before) != 0)
    {
        JuiceRuntimeAppend(self, @"HOST_RUNTIME fd_limit=unavailable\n");
        return;
    }

    struct rlimit requested = before;
    rlim_t target = before.rlim_max;
    if (target == RLIM_INFINITY || target > 1024) target = 1024;
    if (requested.rlim_cur < target) requested.rlim_cur = target;

    BOOL changed = requested.rlim_cur != before.rlim_cur &&
                   setrlimit(RLIMIT_NOFILE, &requested) == 0;

    struct rlimit after = before;
    if (changed) getrlimit(RLIMIT_NOFILE, &after);
    JuiceRuntimeAppend(self, [NSString stringWithFormat:
        @"HOST_RUNTIME sigpipe=ignored fd_limit=%llu hard_limit=%llu raised=%d\n",
        (unsigned long long)after.rlim_cur,
        (unsigned long long)after.rlim_max,
        changed]);
}

static BOOL JuiceStoreFullFrame(id self, JuiceRuntimeMsg message, NSData *data, int clientFD)
{
    if (message.width <= 0 || message.height <= 0 ||
        message.stride < (uint32_t)message.width * 4u)
        return NO;

    uint64_t required = (uint64_t)message.stride * (uint32_t)message.height;
    if (required > data.length || required > UINT32_MAX) return NO;

    JuiceRuntimeFramebuffer *frame = [JuiceRuntimeFramebuffer new];
    frame.bytes = [[NSMutableData alloc] initWithBytes:data.bytes length:(NSUInteger)required];
    frame.width = message.width;
    frame.height = message.height;
    frame.stride = message.stride;
    frame.clientFD = clientFD;
    JuiceFramebuffers(self)[@(message.hwnd)] = frame;
    return YES;
}

static NSData *JuiceMergeDirtyFrame(id self, JuiceRuntimeMsg *message,
                                    NSData *data, int clientFD)
{
    JuiceRuntimeFramebuffer *frame = JuiceFramebuffers(self)[@(message->hwnd)];
    if (!frame)
    {
        JuiceRuntimeAppend(self, [NSString stringWithFormat:
            @"DISPLAY_DIRTY_DROPPED hwnd=0x%llx reason=no-baseline\n",
            (unsigned long long)message->hwnd]);
        return nil;
    }

    if (message->x < 0 || message->y < 0 || message->width <= 0 || message->height <= 0 ||
        message->stride < (uint32_t)message->width * 4u ||
        (uint64_t)(uint32_t)message->x + (uint32_t)message->width > (uint32_t)frame.width ||
        (uint64_t)(uint32_t)message->y + (uint32_t)message->height > (uint32_t)frame.height)
    {
        JuiceRuntimeAppend(self, [NSString stringWithFormat:
            @"DISPLAY_DIRTY_DROPPED hwnd=0x%llx reason=invalid-rect rect=%d,%d %dx%d surface=%dx%d\n",
            (unsigned long long)message->hwnd, message->x, message->y,
            message->width, message->height, frame.width, frame.height]);
        return nil;
    }

    uint64_t required = (uint64_t)message->stride * (uint32_t)message->height;
    if (required > data.length)
    {
        JuiceRuntimeAppend(self, [NSString stringWithFormat:
            @"DISPLAY_DIRTY_DROPPED hwnd=0x%llx reason=short-payload need=%llu have=%lu\n",
            (unsigned long long)message->hwnd, (unsigned long long)required,
            (unsigned long)data.length]);
        return nil;
    }

    size_t rowBytes = (size_t)(uint32_t)message->width * 4u;
    uint8_t *destination = frame.bytes.mutableBytes;
    const uint8_t *source = data.bytes;
    for (int32_t row = 0; row < message->height; row++)
    {
        memcpy(destination + (size_t)(message->y + row) * frame.stride +
                           (size_t)message->x * 4u,
               source + (size_t)row * message->stride,
               rowBytes);
    }
    frame.clientFD = clientFD;

    message->x = 0;
    message->y = 0;
    message->width = frame.width;
    message->height = frame.height;
    message->stride = frame.stride;
    message->size = (uint32_t)frame.bytes.length;
    message->flags &= ~JUICE_FRAME_DIRTY;

    /* The existing UIImage path retains the CFData provider.  Hand it an
       immutable snapshot so later dirty updates cannot mutate pixels that a
       currently displayed CGImage is still reading. */
    return [frame.bytes copy];
}

static void JuiceRuntimePresentFrame(id self, SEL _cmd, JuiceRuntimeMsg message,
                                     NSData *data, int clientFD, pid_t peerPID, BOOL first)
{
    if (message.flags & JUICE_FRAME_DIRTY)
    {
        NSData *merged = JuiceMergeDirtyFrame(self, &message, data, clientFD);
        if (!merged) return;
        data = merged;
        first = NO;
    }
    else
    {
        JuiceStoreFullFrame(self, message, data, clientFD);
    }

    if (JuiceOriginalPresentFrame)
        JuiceOriginalPresentFrame(self, _cmd, message, data, clientFD, peerPID, first);
}

static void JuiceRuntimeDestroyWindow(id self, SEL _cmd, uint64_t hwnd)
{
    [JuiceFramebuffers(self) removeObjectForKey:@(hwnd)];
    if (JuiceOriginalDestroyWindow) JuiceOriginalDestroyWindow(self, _cmd, hwnd);
}

static void JuiceRuntimeRemoveClientWindows(id self, SEL _cmd, int clientFD)
{
    NSMutableDictionary *frames = JuiceFramebuffers(self);
    NSMutableArray<NSNumber *> *remove = [NSMutableArray array];
    [frames enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, JuiceRuntimeFramebuffer *frame, BOOL *stop) {
        (void)stop;
        if (frame.clientFD == clientFD) [remove addObject:key];
    }];
    [frames removeObjectsForKeys:remove];
    if (JuiceOriginalRemoveClientWindows) JuiceOriginalRemoveClientWindows(self, _cmd, clientFD);
}

static void JuiceRuntimeViewDidLoad(id self, SEL _cmd)
{
    ((void (*)(id, SEL))JuiceOriginalViewDidLoad)(self, _cmd);
    JuiceRaiseFileDescriptorLimit(self);
}

__attribute__((constructor))
static void JuiceInstallRuntimeHardening(void)
{
    signal(SIGPIPE, SIG_IGN);

    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;

    Method viewDidLoad = class_getInstanceMethod(cls, NSSelectorFromString(@"viewDidLoad"));
    if (viewDidLoad)
        JuiceOriginalViewDidLoad = method_setImplementation(viewDidLoad, (IMP)JuiceRuntimeViewDidLoad);

    SEL frameSelector = NSSelectorFromString(@"presentFrameMessage:data:client:peerPID:first:");
    Method frame = class_getInstanceMethod(cls, frameSelector);
    if (frame)
        JuiceOriginalPresentFrame = (void (*)(id, SEL, JuiceRuntimeMsg, NSData *, int, pid_t, BOOL))
            method_setImplementation(frame, (IMP)JuiceRuntimePresentFrame);

    SEL destroySelector = NSSelectorFromString(@"destroyWindowHwnd:");
    Method destroy = class_getInstanceMethod(cls, destroySelector);
    if (destroy)
        JuiceOriginalDestroyWindow = (void (*)(id, SEL, uint64_t))
            method_setImplementation(destroy, (IMP)JuiceRuntimeDestroyWindow);

    SEL removeSelector = NSSelectorFromString(@"removeWindowsForClient:");
    Method remove = class_getInstanceMethod(cls, removeSelector);
    if (remove)
        JuiceOriginalRemoveClientWindows = (void (*)(id, SEL, int))
            method_setImplementation(remove, (IMP)JuiceRuntimeRemoveClientWindows);
}
