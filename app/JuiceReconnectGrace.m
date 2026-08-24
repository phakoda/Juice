#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

/*
 * Preserve the last known host-side window geometry across short display
 * socket interruptions. wineios.drv reconnects on demand and forces a fresh
 * full framebuffer for every HWND, so throwing the corresponding WineWindowState
 * away immediately causes the recovered frame to be recreated at (0,0) until
 * Wine happens to emit another WINDOW message.
 *
 * Keep the state for a short grace period and prune only entries that are still
 * byte-for-byte idle from the disconnected client. A reconnect updates the
 * state's image/client FD in presentFrameMessage:, which makes the delayed
 * cleanup leave that HWND alone. Snapshotting image/frame/visibility also makes
 * this safe when Darwin quickly reuses the same numeric file descriptor.
 */

static void (*JuiceOriginalRemoveWindowsForClientGrace)(id, SEL, int);
static const NSTimeInterval JuiceReconnectGraceSeconds = 3.0;

static id JuiceReconnectValue(id object, NSString *key)
{
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceReconnectSetValue(id object, NSString *key, id value)
{
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static void JuiceReconnectAppend(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static NSDictionary *JuiceReconnectSnapshot(id self, int fd)
{
    NSDictionary *windows = JuiceReconnectValue(self, @"wineWindows");
    if (![windows isKindOfClass:NSDictionary.class]) return @{};

    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    [windows enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, id state, BOOL *stop) {
        (void)stop;
        if ([JuiceReconnectValue(state, @"clientFD") intValue] != fd) return;
        id image = JuiceReconnectValue(state, @"image") ?: NSNull.null;
        id frame = JuiceReconnectValue(state, @"frame") ?: NSNull.null;
        id visible = JuiceReconnectValue(state, @"visible") ?: @NO;
        snapshot[key] = @{ @"state": state,
                           @"image": image,
                           @"frame": frame,
                           @"visible": visible };
    }];
    return snapshot;
}

static BOOL JuiceReconnectStateIsUnchanged(id state, NSDictionary *before, int fd)
{
    if (!state || state != before[@"state"]) return NO;
    if ([JuiceReconnectValue(state, @"clientFD") intValue] != fd) return NO;

    id oldImage = before[@"image"];
    id image = JuiceReconnectValue(state, @"image") ?: NSNull.null;
    if (image != oldImage) return NO;

    id oldFrame = before[@"frame"];
    id frame = JuiceReconnectValue(state, @"frame") ?: NSNull.null;
    if (![frame isEqual:oldFrame]) return NO;

    id oldVisible = before[@"visible"];
    id visible = JuiceReconnectValue(state, @"visible") ?: @NO;
    return [visible isEqual:oldVisible];
}

static void JuiceReconnectRemoveWindows(id self, SEL _cmd, int fd)
{
    NSDictionary *snapshot = JuiceReconnectSnapshot(self, fd);
    if (!snapshot.count)
    {
        if (JuiceOriginalRemoveWindowsForClientGrace)
            JuiceOriginalRemoveWindowsForClientGrace(self, _cmd, fd);
        return;
    }

    /* Input must never target a closed descriptor while the visual state is
       retained. The next pointer/key event will bind to the reconnected state. */
    if ([JuiceReconnectValue(self, @"inputClient") intValue] == fd)
    {
        JuiceReconnectSetValue(self, @"inputClient", @(-1));
        JuiceReconnectSetValue(self, @"inputHwnd", @0);
    }
    if ([JuiceReconnectValue(self, @"activeClient") intValue] == fd)
        JuiceReconnectSetValue(self, @"activeClient", @(-1));

    JuiceReconnectAppend(self, [NSString stringWithFormat:
        @"DISPLAY_RECONNECT_GRACE fd=%d windows=%lu seconds=%.1f\n",
        fd, (unsigned long)snapshot.count, JuiceReconnectGraceSeconds]);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(JuiceReconnectGraceSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSMutableDictionary *windows = JuiceReconnectValue(self, @"wineWindows");
        NSMutableArray *order = JuiceReconnectValue(self, @"wineWindowOrder");
        if (![windows isKindOfClass:NSMutableDictionary.class] ||
            ![order isKindOfClass:NSMutableArray.class])
        {
            if (JuiceOriginalRemoveWindowsForClientGrace)
                JuiceOriginalRemoveWindowsForClientGrace(self, _cmd, fd);
            return;
        }

        NSMutableArray<NSNumber *> *remove = [NSMutableArray array];
        [snapshot enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSDictionary *before, BOOL *stop) {
            (void)stop;
            id state = windows[key];
            if (JuiceReconnectStateIsUnchanged(state, before, fd)) [remove addObject:key];
        }];

        for (NSNumber *key in remove) [windows removeObjectForKey:key];
        [order removeObjectsInArray:remove];

        if (remove.count)
        {
            SEL composite = NSSelectorFromString(@"compositeWineDesktop");
            if ([self respondsToSelector:composite] &&
                [JuiceReconnectValue(self, @"experimentalMultiWindow") boolValue])
                ((void (*)(id, SEL))objc_msgSend)(self, composite);
        }

        JuiceReconnectAppend(self, [NSString stringWithFormat:
            @"DISPLAY_RECONNECT_GRACE_END fd=%d preserved=%lu removed=%lu\n",
            fd, (unsigned long)(snapshot.count - remove.count), (unsigned long)remove.count]);
    });
}

__attribute__((constructor))
static void JuiceInstallReconnectGrace(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(@"removeWindowsForClient:"));
    if (!method) return;
    JuiceOriginalRemoveWindowsForClientGrace = (void (*)(id, SEL, int))
        method_setImplementation(method, (IMP)JuiceReconnectRemoveWindows);
}
