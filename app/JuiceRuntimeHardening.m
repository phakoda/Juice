#import <UIKit/UIKit.h>
#import <errno.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <signal.h>
#import <string.h>
#import <sys/resource.h>
#import <sys/types.h>
#import <sys/socket.h>
#import <unistd.h>

#define JUICE_MAGIC 0x4a554943u
#define JUICE_MSG_HELLO 1u
#define JUICE_MSG_WINDOW 3u
#define JUICE_MSG_DESTROY 4u
#define JUICE_MSG_FRAME 5u
#define JUICE_FRAME_DIRTY 0x20000000u
#define JUICE_MAX_FRAME_BYTES (128u * 1024u * 1024u)

typedef struct
{
    uint32_t magic, type, size;
    uint64_t hwnd;
    int32_t x, y, width, height;
    uint32_t stride, flags;
} JuiceRuntimeMsg;

@interface JuiceRuntimeFramebuffer : NSObject
@property(nonatomic,strong) NSMutableData *bytes;
@property(nonatomic) uint64_t hwnd;
@property(nonatomic) int32_t width;
@property(nonatomic) int32_t height;
@property(nonatomic) uint32_t stride;
@property(nonatomic) int clientFD;
@property(nonatomic) pid_t peerPID;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger receivedFrames;
@property(nonatomic) NSUInteger renderedFrames;
@property(nonatomic) NSUInteger coalescedFrames;
@property(nonatomic) BOOL renderScheduled;
@property(nonatomic) BOOL firstPending;
@property(nonatomic) BOOL invalidated;
@end
@implementation JuiceRuntimeFramebuffer
@end

/*
 * Host-process reliability fixes that are independent of Wine itself.
 *
 *  - Ignore SIGPIPE so normal socket/pipe disconnects become EPIPE instead of
 *    killing the UIKit process.
 *  - Raise the soft descriptor limit toward 1024 where Darwin permits it.
 *  - Validate display messages before allocating their payloads.
 *  - Keep one mutable framebuffer per HWND and merge packed dirty rectangles.
 *  - Coalesce producer frames before dispatching to UIKit. There is at most
 *    one pending main-queue render per HWND, so a 60+ FPS Wine process cannot
 *    create an unbounded queue of multi-megabyte NSData/UIImage work items.
 *
 * The existing main.m presentation/compositor code remains the final renderer;
 * this module only feeds it validated, immutable, full-frame snapshots.
 */

static IMP JuiceOriginalViewDidLoad;
static void (*JuiceOriginalDestroyWindow)(id, SEL, uint64_t);
static void (*JuiceOriginalRemoveClientWindows)(id, SEL, int);
static char JuiceRuntimeFramebuffersKey;

static void JuiceRuntimeAppend(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static id JuiceRuntimeValue(id self, NSString *key)
{
    @try { return [self valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceRuntimeSetValue(id self, NSString *key, id value)
{
    @try { [self setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static NSMutableDictionary<NSNumber *, JuiceRuntimeFramebuffer *> *JuiceFramebuffers(id self)
{
    NSMutableDictionary *frames = objc_getAssociatedObject(self, &JuiceRuntimeFramebuffersKey);
    if (!frames)
    {
        @synchronized(self)
        {
            frames = objc_getAssociatedObject(self, &JuiceRuntimeFramebuffersKey);
            if (!frames)
            {
                frames = [NSMutableDictionary dictionary];
                objc_setAssociatedObject(self, &JuiceRuntimeFramebuffersKey, frames,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    return frames;
}

static BOOL JuiceReadAll(int fd, void *buffer, size_t length)
{
    uint8_t *cursor = buffer;
    while (length)
    {
        ssize_t count = read(fd, cursor, length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        cursor += count;
        length -= (size_t)count;
    }
    return YES;
}

static BOOL JuiceFrameHeaderIsValid(JuiceRuntimeMsg message)
{
    if (message.width <= 0 || message.height <= 0) return NO;
    if ((uint64_t)(uint32_t)message.width * 4u > message.stride) return NO;
    uint64_t expected = (uint64_t)message.stride * (uint32_t)message.height;
    return expected == message.size && expected <= JUICE_MAX_FRAME_BYTES;
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
        @"HOST_RUNTIME sigpipe=ignored fd_limit=%llu hard_limit=%llu raised=%d frame_cap=%u\n",
        (unsigned long long)after.rlim_cur,
        (unsigned long long)after.rlim_max,
        changed, JUICE_MAX_FRAME_BYTES]);
}

static JuiceRuntimeFramebuffer *JuiceLookupFramebuffer(id self, uint64_t hwnd)
{
    NSMutableDictionary *frames = JuiceFramebuffers(self);
    @synchronized(frames) { return frames[@(hwnd)]; }
}

static JuiceRuntimeFramebuffer *JuiceCreateFramebuffer(id self, JuiceRuntimeMsg message,
                                                        NSData *data, int clientFD, pid_t peerPID)
{
    if (!JuiceFrameHeaderIsValid(message) || data.length != message.size) return nil;

    JuiceRuntimeFramebuffer *frame = [JuiceRuntimeFramebuffer new];
    if ([data isKindOfClass:NSMutableData.class])
        frame.bytes = (NSMutableData *)data;
    else
        frame.bytes = [data mutableCopy];
    frame.hwnd = message.hwnd;
    frame.width = message.width;
    frame.height = message.height;
    frame.stride = message.stride;
    frame.clientFD = clientFD;
    frame.peerPID = peerPID;
    frame.generation = 1;
    frame.receivedFrames = 1;

    NSMutableDictionary *frames = JuiceFramebuffers(self);
    @synchronized(frames)
    {
        JuiceRuntimeFramebuffer *old = frames[@(message.hwnd)];
        if (old) @synchronized(old) { old.invalidated = YES; }
        frames[@(message.hwnd)] = frame;
    }
    return frame;
}

static JuiceRuntimeFramebuffer *JuiceApplyFrame(id self, JuiceRuntimeMsg message,
                                                 NSData *data, int clientFD, pid_t peerPID)
{
    if (!(message.flags & JUICE_FRAME_DIRTY))
        return JuiceCreateFramebuffer(self, message, data, clientFD, peerPID);

    JuiceRuntimeFramebuffer *frame = JuiceLookupFramebuffer(self, message.hwnd);
    if (!frame)
    {
        JuiceRuntimeAppend(self, [NSString stringWithFormat:
            @"DISPLAY_DIRTY_DROPPED hwnd=0x%llx reason=no-baseline\n",
            (unsigned long long)message.hwnd]);
        return nil;
    }

    @synchronized(frame)
    {
        if (frame.invalidated) return nil;
        if (!JuiceFrameHeaderIsValid(message) || data.length != message.size ||
            message.x < 0 || message.y < 0 ||
            (uint64_t)(uint32_t)message.x + (uint32_t)message.width > (uint32_t)frame.width ||
            (uint64_t)(uint32_t)message.y + (uint32_t)message.height > (uint32_t)frame.height)
        {
            JuiceRuntimeAppend(self, [NSString stringWithFormat:
                @"DISPLAY_DIRTY_DROPPED hwnd=0x%llx reason=invalid-update rect=%d,%d %dx%d bytes=%u\n",
                (unsigned long long)message.hwnd, message.x, message.y,
                message.width, message.height, message.size]);
            return nil;
        }

        size_t rowBytes = (size_t)(uint32_t)message.width * 4u;
        uint8_t *destination = frame.bytes.mutableBytes;
        const uint8_t *source = data.bytes;
        for (int32_t row = 0; row < message.height; row++)
        {
            memcpy(destination + (size_t)(message.y + row) * frame.stride +
                               (size_t)message.x * 4u,
                   source + (size_t)row * message.stride,
                   rowBytes);
        }
        frame.clientFD = clientFD;
        frame.peerPID = peerPID;
        frame.generation++;
        frame.receivedFrames++;
    }
    return frame;
}

static void JuiceDeliverFramebuffer(id self, JuiceRuntimeFramebuffer *frame);

static void JuiceScheduleFramebuffer(id self, JuiceRuntimeFramebuffer *frame, BOOL first)
{
    BOOL schedule = NO;
    @synchronized(frame)
    {
        if (frame.invalidated) return;
        if (first) frame.firstPending = YES;
        if (!frame.renderScheduled)
        {
            frame.renderScheduled = YES;
            schedule = YES;
        }
        else
        {
            frame.coalescedFrames++;
        }
    }
    if (schedule)
        dispatch_async(dispatch_get_main_queue(), ^{ JuiceDeliverFramebuffer(self, frame); });
}

static void JuiceDeliverFramebuffer(id self, JuiceRuntimeFramebuffer *frame)
{
    NSData *snapshot;
    int32_t width, height;
    uint32_t stride;
    int clientFD;
    pid_t peerPID;
    uint64_t hwnd;
    NSUInteger generation;
    BOOL first;

    @synchronized(frame)
    {
        if (frame.invalidated)
        {
            frame.renderScheduled = NO;
            return;
        }
        snapshot = [frame.bytes copy];
        hwnd = frame.hwnd;
        width = frame.width;
        height = frame.height;
        stride = frame.stride;
        clientFD = frame.clientFD;
        peerPID = frame.peerPID;
        generation = frame.generation;
        first = frame.firstPending;
        frame.firstPending = NO;
        frame.renderedFrames++;
    }

    JuiceRuntimeMsg message = {
        JUICE_MAGIC, JUICE_MSG_FRAME, (uint32_t)snapshot.length, hwnd,
        0, 0, width, height, stride, 0
    };

    SEL presentSelector = NSSelectorFromString(@"presentFrameMessage:data:client:peerPID:first:");
    if ([self respondsToSelector:presentSelector])
    {
        ((void (*)(id, SEL, JuiceRuntimeMsg, NSData *, int, pid_t, BOOL))objc_msgSend)
            (self, presentSelector, message, snapshot, clientFD, peerPID, first);
    }

    BOOL again = NO;
    @synchronized(frame)
    {
        if (frame.invalidated)
            frame.renderScheduled = NO;
        else if (frame.generation != generation)
            again = YES;
        else
            frame.renderScheduled = NO;
    }
    if (again)
        dispatch_async(dispatch_get_main_queue(), ^{ JuiceDeliverFramebuffer(self, frame); });
}

static void JuiceUpdateDesktopSize(id self, int32_t width, int32_t height)
{
    if (width <= 0 || height <= 0) return;
    SEL selector = NSSelectorFromString(@"setWineDesktopSize:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, CGSize))objc_msgSend)(self, selector, CGSizeMake(width, height));
}

static void JuiceInvokeWindowUpdate(id self, JuiceRuntimeMsg message, int fd)
{
    SEL selector = NSSelectorFromString(@"updateWindowMessage:client:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, JuiceRuntimeMsg, int))objc_msgSend)(self, selector, message, fd);
}

static void JuiceInvokeDestroy(id self, uint64_t hwnd)
{
    SEL selector = NSSelectorFromString(@"destroyWindowHwnd:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, uint64_t))objc_msgSend)(self, selector, hwnd);
}

static void JuiceInvalidateClientFrames(id self, int clientFD)
{
    NSMutableDictionary *frames = JuiceFramebuffers(self);
    NSMutableArray<NSNumber *> *remove = [NSMutableArray array];
    NSUInteger received = 0, rendered = 0, coalesced = 0;
    @synchronized(frames)
    {
        [frames enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, JuiceRuntimeFramebuffer *frame, BOOL *stop) {
            (void)stop;
            @synchronized(frame)
            {
                if (frame.clientFD == clientFD)
                {
                    frame.invalidated = YES;
                    received += frame.receivedFrames;
                    rendered += frame.renderedFrames;
                    coalesced += frame.coalescedFrames;
                    [remove addObject:key];
                }
            }
        }];
        [frames removeObjectsForKeys:remove];
    }
    if (received)
        JuiceRuntimeAppend(self, [NSString stringWithFormat:
            @"DISPLAY_COALESCE fd=%d received=%lu rendered=%lu merged_while_pending=%lu windows=%lu\n",
            clientFD, (unsigned long)received, (unsigned long)rendered,
            (unsigned long)coalesced, (unsigned long)remove.count]);
}

static void JuiceRuntimeReadClient(id self, SEL _cmd, int fd)
{
    (void)_cmd;
    pid_t peerPID = 0;
    NSUInteger frameCount = 0;
    BOOL firstFrame = YES;

#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif

    for (;;)
    {
        @autoreleasepool
        {
            JuiceRuntimeMsg message;
            if (!JuiceReadAll(fd, &message, sizeof(message))) break;
            if (message.magic != JUICE_MAGIC)
            {
                JuiceRuntimeAppend(self, [NSString stringWithFormat:
                    @"DISPLAY_PROTOCOL_REJECTED fd=%d reason=magic value=%08x\n", fd, message.magic]);
                break;
            }

            BOOL fixedMessage = message.type == JUICE_MSG_HELLO ||
                                message.type == JUICE_MSG_WINDOW ||
                                message.type == JUICE_MSG_DESTROY;
            if (fixedMessage && message.size != 0)
            {
                JuiceRuntimeAppend(self, [NSString stringWithFormat:
                    @"DISPLAY_PROTOCOL_REJECTED fd=%d type=%u reason=unexpected-payload bytes=%u\n",
                    fd, message.type, message.size]);
                break;
            }
            if (message.type == JUICE_MSG_FRAME && !JuiceFrameHeaderIsValid(message))
            {
                JuiceRuntimeAppend(self, [NSString stringWithFormat:
                    @"DISPLAY_PROTOCOL_REJECTED fd=%d type=frame rect=%d,%d %dx%d stride=%u bytes=%u\n",
                    fd, message.x, message.y, message.width, message.height,
                    message.stride, message.size]);
                break;
            }
            if (message.type != JUICE_MSG_FRAME && !fixedMessage)
            {
                JuiceRuntimeAppend(self, [NSString stringWithFormat:
                    @"DISPLAY_PROTOCOL_REJECTED fd=%d reason=unknown-type type=%u bytes=%u\n",
                    fd, message.type, message.size]);
                break;
            }

            NSMutableData *data = nil;
            if (message.size)
            {
                data = [NSMutableData dataWithLength:message.size];
                if (!data || !JuiceReadAll(fd, data.mutableBytes, message.size)) break;
            }

            if (message.type == JUICE_MSG_HELLO)
            {
                peerPID = (pid_t)message.flags;
                JuiceRuntimeAppend(self, [NSString stringWithFormat:
                    @"DISPLAY_EVENT HELLO fd=%d pid=%d desktop=%dx%d dpi=%u\n",
                    fd, peerPID, message.width, message.height, message.stride]);
                dispatch_async(dispatch_get_main_queue(), ^{
                    JuiceUpdateDesktopSize(self, message.width, message.height);
                });
            }
            else if (message.type == JUICE_MSG_WINDOW)
            {
                JuiceRuntimeAppend(self, [NSString stringWithFormat:
                    @"DISPLAY_EVENT WINDOW pid=%d hwnd=0x%llx rect=%d,%d %dx%d visible=%u\n",
                    peerPID, (unsigned long long)message.hwnd, message.x, message.y,
                    message.width, message.height, message.flags]);
                dispatch_async(dispatch_get_main_queue(), ^{ JuiceInvokeWindowUpdate(self, message, fd); });
            }
            else if (message.type == JUICE_MSG_DESTROY)
            {
                JuiceRuntimeAppend(self, [NSString stringWithFormat:
                    @"DISPLAY_EVENT DESTROY pid=%d hwnd=0x%llx\n",
                    peerPID, (unsigned long long)message.hwnd]);
                dispatch_async(dispatch_get_main_queue(), ^{ JuiceInvokeDestroy(self, message.hwnd); });
            }
            else if (message.type == JUICE_MSG_FRAME)
            {
                JuiceRuntimeFramebuffer *frame = JuiceApplyFrame(self, message, data, fd, peerPID);
                if (!frame) continue;

                frameCount++;
                if (frameCount <= 3)
                    JuiceRuntimeAppend(self, [NSString stringWithFormat:
                        @"DISPLAY_EVENT FRAME pid=%d hwnd=0x%llx dirty=%d rect=%d,%d %dx%d stride=%u bytes=%u count=%lu\n",
                        peerPID, (unsigned long long)message.hwnd,
                        !!(message.flags & JUICE_FRAME_DIRTY), message.x, message.y,
                        message.width, message.height, message.stride, message.size,
                        (unsigned long)frameCount]);

                BOOL reportFirst = firstFrame;
                firstFrame = NO;
                JuiceScheduleFramebuffer(self, frame, reportFirst);
            }
        }
    }

    JuiceRuntimeAppend(self, [NSString stringWithFormat:
        @"DISPLAY_CLIENT_CLOSED fd=%d pid=%d frames=%lu\n",
        fd, peerPID, (unsigned long)frameCount]);
    close(fd);
    JuiceInvalidateClientFrames(self, fd);

    NSMutableArray *clients = JuiceRuntimeValue(self, @"clients");
    if ([clients isKindOfClass:NSMutableArray.class])
    {
        @synchronized(clients) { [clients removeObject:@(fd)]; }
    }
    NSNumber *active = JuiceRuntimeValue(self, @"activeClient");
    if (active.intValue == fd) JuiceRuntimeSetValue(self, @"activeClient", @(-1));

    dispatch_async(dispatch_get_main_queue(), ^{
        SEL selector = NSSelectorFromString(@"removeWindowsForClient:");
        if ([self respondsToSelector:selector])
            ((void (*)(id, SEL, int))objc_msgSend)(self, selector, fd);
    });
}

static void JuiceRuntimeDestroyWindow(id self, SEL _cmd, uint64_t hwnd)
{
    NSMutableDictionary *frames = JuiceFramebuffers(self);
    @synchronized(frames)
    {
        JuiceRuntimeFramebuffer *frame = frames[@(hwnd)];
        if (frame) @synchronized(frame) { frame.invalidated = YES; }
        [frames removeObjectForKey:@(hwnd)];
    }
    if (JuiceOriginalDestroyWindow) JuiceOriginalDestroyWindow(self, _cmd, hwnd);
}

static void JuiceRuntimeRemoveClientWindows(id self, SEL _cmd, int clientFD)
{
    JuiceInvalidateClientFrames(self, clientFD);
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

    Method readClient = class_getInstanceMethod(cls, NSSelectorFromString(@"readClient:"));
    if (readClient)
        method_setImplementation(readClient, (IMP)JuiceRuntimeReadClient);

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
