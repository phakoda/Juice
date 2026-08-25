#import <Foundation/Foundation.h>
#import <errno.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdint.h>
#import <string.h>
#import <unistd.h>
#import "../wine/dlls/wineios.drv/control_protocol.h"

#define JUICE_HOST_IO_MAGIC 0x4a554943u

typedef struct
{
    uint32_t magic, type, size;
    uint64_t hwnd;
    int32_t x, y, width, height;
    uint32_t stride, flags;
} JuiceHostIOMessage;

/*
 * Robust host wire I/O.
 *
 * main.m's compact ReadAll/WriteAll helpers predate the runtime hardening and
 * treat an interrupted read/write as a failed connection. That is especially
 * visible now that pointer hover/wheel and keyboard traffic are frequent. Keep
 * each display write serialized under the existing clients lock, retry EINTR,
 * and make the dedicated control socket use the same exact-write semantics.
 */

static id JuiceHostIOValue(id object, NSString *key)
{
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceHostIOSetValue(id object, NSString *key, id value)
{
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static void JuiceHostIOAppend(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static BOOL JuiceHostIOReadAll(int fd, void *buffer, size_t length)
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

static BOOL JuiceHostIOWriteAll(int fd, const void *buffer, size_t length)
{
    const uint8_t *cursor = buffer;
    while (length)
    {
        ssize_t count = write(fd, cursor, length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        cursor += count;
        length -= (size_t)count;
    }
    return YES;
}

static void JuiceCopyControlString(char *destination, size_t capacity, NSString *value)
{
    if (!capacity) return;
    destination[0] = 0;
    if (!value.length) return;
    [value getCString:destination maxLength:capacity encoding:NSUTF8StringEncoding];
    destination[capacity - 1] = 0;
}

static BOOL JuiceHardenedSendMessage(id self, SEL _cmd, JuiceHostIOMessage *message,
                                     NSData *payload, int fd)
{
    (void)_cmd;
    if (!message || fd < 0 || payload.length > UINT32_MAX) return NO;
    message->size = (uint32_t)payload.length;

    NSMutableArray *clients = JuiceHostIOValue(self, @"clients");
    if (![clients isKindOfClass:NSMutableArray.class]) return NO;
    @synchronized(clients)
    {
        if (![clients containsObject:@(fd)]) return NO;
        if (!JuiceHostIOWriteAll(fd, message, sizeof(*message))) return NO;
        if (payload.length && !JuiceHostIOWriteAll(fd, payload.bytes, payload.length)) return NO;
    }
    return YES;
}

static void JuiceHardenedBroadcast(id self, SEL _cmd, const void *buffer, size_t length)
{
    (void)_cmd;
    if (!buffer || !length) return;
    int fd = [JuiceHostIOValue(self, @"activeClient") intValue];
    if (fd < 0) return;

    NSMutableArray *clients = JuiceHostIOValue(self, @"clients");
    if (![clients isKindOfClass:NSMutableArray.class]) return;
    @synchronized(clients)
    {
        if ([clients containsObject:@(fd)] && !JuiceHostIOWriteAll(fd, buffer, length))
            JuiceHostIOAppend(self, [NSString stringWithFormat:
                @"HOST_IO_WRITE_FAILED channel=display fd=%d errno=%d bytes=%lu\n",
                fd, errno, (unsigned long)length]);
    }
}

static void JuiceHardenedControlResponse(id self, SEL _cmd, int fd, uint32_t request,
                                         int32_t status, NSString *path, NSString *detail)
{
    (void)_cmd;
    struct juice_control_message message = {0};
    message.magic = JUICE_CONTROL_MAGIC;
    message.version = JUICE_CONTROL_VERSION;
    message.type = JUICE_CONTROL_IMPORT_RESPONSE;
    message.size = sizeof(message);
    message.request_id = request;
    message.status = status;
    JuiceCopyControlString(message.path, sizeof(message.path), path);
    JuiceCopyControlString(message.detail, sizeof(message.detail), detail);
    NSData *wire = [NSData dataWithBytes:&message length:sizeof(message)];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL written = JuiceHostIOWriteAll(fd, wire.bytes, wire.length);
        int saved = written ? 0 : errno;
        close(fd);
        if (!written)
            JuiceHostIOAppend(self, [NSString stringWithFormat:
                @"HOST_IO_WRITE_FAILED channel=control fd=%d request=%u errno=%d\n",
                fd, request, saved]);
    });
}

static void JuiceSendControlResponse(id self, int fd, uint32_t request, int32_t status,
                                     NSString *path, NSString *detail)
{
    SEL selector = NSSelectorFromString(@"sendControlResponseToFD:request:status:path:detail:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, int, uint32_t, int32_t, id, id))objc_msgSend)
            (self, selector, fd, request, status, path ?: @"", detail ?: @"");
    else close(fd);
}

static void JuiceHardenedReadControlClient(id self, SEL _cmd, int fd)
{
    (void)_cmd;
    struct juice_control_message message;
    if (!JuiceHostIOReadAll(fd, &message, sizeof(message)) ||
        message.magic != JUICE_CONTROL_MAGIC ||
        message.version != JUICE_CONTROL_VERSION ||
        message.size != sizeof(message))
    {
        JuiceHostIOAppend(self, [NSString stringWithFormat:
            @"CONTROL_V1_PROTOCOL_REJECTED fd=%d errno=%d\n", fd, errno]);
        close(fd);
        return;
    }

    if (message.type == JUICE_CONTROL_IMPORT_REQUEST)
    {
        BOOL busy = NO;
        @synchronized(self)
        {
            if ([JuiceHostIOValue(self, @"controlPickerFD") intValue] >= 0)
                busy = YES;
            else
            {
                JuiceHostIOSetValue(self, @"controlPickerFD", @(fd));
                JuiceHostIOSetValue(self, @"controlRequestID", @(message.request_id));
                JuiceHostIOSetValue(self, @"controlFilters", @(message.flags));
            }
        }
        if (busy)
        {
            JuiceSendControlResponse(self, fd, message.request_id,
                                     JUICE_CONTROL_STATUS_ERROR, @"",
                                     @"Another Juice import request is already active.");
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            SEL selector = NSSelectorFromString(@"presentControlPicker");
            if ([self respondsToSelector:selector])
                ((void (*)(id, SEL))objc_msgSend)(self, selector);
            else
            {
                @synchronized(self)
                {
                    if ([JuiceHostIOValue(self, @"controlPickerFD") intValue] == fd)
                    {
                        JuiceHostIOSetValue(self, @"controlPickerFD", @(-1));
                        JuiceHostIOSetValue(self, @"controlRequestID", @0);
                        JuiceHostIOSetValue(self, @"controlFilters", @0);
                    }
                }
                JuiceSendControlResponse(self, fd, message.request_id,
                                         JUICE_CONTROL_STATUS_ERROR, @"",
                                         @"The host file picker is unavailable.");
            }
        });
        return; /* picker owns fd until completion/cancellation */
    }

    if (message.type == JUICE_CONTROL_HOST_ACTION)
    {
        size_t length = strnlen(message.path, sizeof(message.path));
        NSString *path = [[NSString alloc] initWithBytes:message.path length:length
                                                encoding:NSUTF8StringEncoding] ?: @"";
        uint32_t action = message.flags;
        close(fd);
        dispatch_async(dispatch_get_main_queue(), ^{
            SEL selector = NSSelectorFromString(@"handleControlAction:path:");
            if ([self respondsToSelector:selector])
                ((void (*)(id, SEL, uint32_t, id))objc_msgSend)(self, selector, action, path);
        });
        return;
    }

    JuiceHostIOAppend(self, [NSString stringWithFormat:
        @"CONTROL_V1_PROTOCOL_REJECTED fd=%d type=%u reason=unknown-type\n",
        fd, message.type]);
    close(fd);
}

__attribute__((constructor(220)))
static void JuiceInstallHostIOHardening(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;

    Method send = class_getInstanceMethod(cls, NSSelectorFromString(@"sendMessage:payload:toFD:"));
    if (send) method_setImplementation(send, (IMP)JuiceHardenedSendMessage);

    Method broadcast = class_getInstanceMethod(cls, NSSelectorFromString(@"broadcast:size:"));
    if (broadcast) method_setImplementation(broadcast, (IMP)JuiceHardenedBroadcast);

    Method response = class_getInstanceMethod(cls,
        NSSelectorFromString(@"sendControlResponseToFD:request:status:path:detail:"));
    if (response) method_setImplementation(response, (IMP)JuiceHardenedControlResponse);

    Method readControl = class_getInstanceMethod(cls, NSSelectorFromString(@"readControlClient:"));
    if (readControl) method_setImplementation(readControl, (IMP)JuiceHardenedReadControlClient);
}
