#import <Foundation/Foundation.h>
#import <errno.h>
#import <fcntl.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

/*
 * Socket lifecycle and descriptor hygiene for the UIKit host.
 *
 * The sandbox-path layer moved listeners into NSTemporaryDirectory(), but its
 * listener/accepted descriptors can still leak into Wine children on SDKs or
 * execution paths where POSIX_SPAWN_CLOEXEC_DEFAULT is unavailable. It also
 * lets an accept loop disappear permanently after one non-EINTR transient
 * failure. Keep every socket close-on-exec, suppress per-socket SIGPIPE where
 * Darwin supports it, and make transient accept failures recoverable.
 */

static id JuiceSocketValue(id object, NSString *key)
{
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceSocketSetValue(id object, NSString *key, id value)
{
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static void JuiceSocketAppend(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static NSString *JuiceSocketRoot(void)
{
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"JuiceSockets"];
}

static void JuiceSetCloseOnExec(int fd)
{
    if (fd < 0) return;
    int flags = fcntl(fd, F_GETFD);
    if (flags >= 0) fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
}

static BOOL JuiceBindListener(NSString *path, int backlog, int *fdOut, int *errorOut)
{
    if (fdOut) *fdOut = -1;
    if (errorOut) *errorOut = 0;
    const char *wirePath = path.fileSystemRepresentation;
    if (!wirePath || strlen(wirePath) >= sizeof(((struct sockaddr_un *)0)->sun_path))
    {
        if (errorOut) *errorOut = ENAMETOOLONG;
        return NO;
    }

    unlink(wirePath);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
    {
        if (errorOut) *errorOut = errno;
        return NO;
    }
    JuiceSetCloseOnExec(fd);

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, wirePath, sizeof(address.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, backlog) != 0)
    {
        int saved = errno;
        close(fd);
        unlink(wirePath);
        if (errorOut) *errorOut = saved;
        return NO;
    }

    if (fdOut) *fdOut = fd;
    return YES;
}

static BOOL JuiceTransientAcceptError(int error)
{
    switch (error)
    {
        case EINTR:
        case ECONNABORTED:
        case EMFILE:
        case ENFILE:
        case ENOBUFS:
        case ENOMEM:
#if EAGAIN != EWOULDBLOCK
        case EAGAIN:
#endif
        case EWOULDBLOCK:
            return YES;
        default:
            return NO;
    }
}

static void JuiceListenerEnded(id self, NSString *fdKey, NSString *pathKey,
                               int listener, NSString *kind, int error)
{
    int current = [JuiceSocketValue(self, fdKey) intValue];
    if (current != listener) return; /* superseded by a foreground restart */

    close(listener);
    JuiceSocketSetValue(self, fdKey, @(-1));
    NSString *path = JuiceSocketValue(self, pathKey);
    if (path.length) unlink(path.fileSystemRepresentation);
    JuiceSocketAppend(self, [NSString stringWithFormat:
        @"SOCKET_LISTENER_ENDED kind=%@ fd=%d errno=%d restart_on_foreground=1\n",
        kind, listener, error]);
}

static void JuiceAcceptDisplayLoop(id self, int listener)
{
    unsigned int failures = 0;
    int finalError = 0;
    for (;;)
    {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0)
        {
            int saved = errno;
            if (saved == EINTR) continue;
            if (JuiceTransientAcceptError(saved) && failures++ < 20)
            {
                if (failures == 1)
                    JuiceSocketAppend(self, [NSString stringWithFormat:
                        @"SOCKET_ACCEPT_RETRY kind=display fd=%d errno=%d\n", listener, saved]);
                usleep(saved == EMFILE || saved == ENFILE ? 100000 : 20000);
                continue;
            }
            finalError = saved;
            break;
        }
        failures = 0;
        JuiceSetCloseOnExec(fd);

        NSMutableArray *clients = JuiceSocketValue(self, @"clients");
        if ([clients isKindOfClass:NSMutableArray.class])
            @synchronized(clients) { [clients addObject:@(fd)]; }
        JuiceSocketAppend(self, [NSString stringWithFormat:
            @"DISPLAY_CLIENT_CONNECTED fd=%d cloexec=1\n", fd]);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            SEL selector = NSSelectorFromString(@"readClient:");
            if ([self respondsToSelector:selector])
                ((void (*)(id, SEL, int))objc_msgSend)(self, selector, fd);
            else close(fd);
        });
    }
    JuiceListenerEnded(self, @"listenFD", @"socketPath", listener, @"display", finalError);
}

static void JuiceAcceptControlLoop(id self, int listener)
{
    unsigned int failures = 0;
    int finalError = 0;
    for (;;)
    {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0)
        {
            int saved = errno;
            if (saved == EINTR) continue;
            if (JuiceTransientAcceptError(saved) && failures++ < 20)
            {
                if (failures == 1)
                    JuiceSocketAppend(self, [NSString stringWithFormat:
                        @"SOCKET_ACCEPT_RETRY kind=control fd=%d errno=%d\n", listener, saved]);
                usleep(saved == EMFILE || saved == ENFILE ? 100000 : 20000);
                continue;
            }
            finalError = saved;
            break;
        }
        failures = 0;
        JuiceSetCloseOnExec(fd);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            SEL selector = NSSelectorFromString(@"readControlClient:");
            if ([self respondsToSelector:selector])
                ((void (*)(id, SEL, int))objc_msgSend)(self, selector, fd);
            else close(fd);
        });
    }
    JuiceListenerEnded(self, @"controlListenFD", @"controlSocketPath", listener, @"control", finalError);
}

static void JuiceStartHardenedListener(id self, BOOL control)
{
    NSString *root = JuiceSocketRoot();
    NSError *directoryError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:root
                             withIntermediateDirectories:YES attributes:nil error:&directoryError];
    NSString *name = control ? @"control.sock" : @"display.sock";
    NSString *path = [root stringByAppendingPathComponent:name];
    NSString *fdKey = control ? @"controlListenFD" : @"listenFD";
    NSString *pathKey = control ? @"controlSocketPath" : @"socketPath";
    JuiceSocketSetValue(self, pathKey, path);

    int listener = -1;
    int saved = directoryError ? EACCES : 0;
    BOOL ready = !directoryError && JuiceBindListener(path, control ? 4 : 8, &listener, &saved);
    JuiceSocketSetValue(self, fdKey, @(listener));
    JuiceSocketAppend(self, [NSString stringWithFormat:
        @"%@ path=%@ ready=%d fd=%d errno=%d sandbox_safe=1 cloexec=1 resilient_accept=1\n",
        control ? @"CONTROL_V1_SOCKET" : @"DISPLAY_SOCKET",
        path, ready, listener, saved]);
    if (!ready) return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (control) JuiceAcceptControlLoop(self, listener);
        else JuiceAcceptDisplayLoop(self, listener);
    });
}

static void JuiceSocketStartDisplay(id self, SEL _cmd)
{
    (void)_cmd;
    JuiceStartHardenedListener(self, NO);
}

static void JuiceSocketStartControl(id self, SEL _cmd)
{
    (void)_cmd;
    JuiceStartHardenedListener(self, YES);
}

/* Install after JuiceStoragePaths (150) so these listener implementations keep
 * its sandbox-safe layout while adding descriptor and retry semantics. */
__attribute__((constructor(200)))
static void JuiceInstallSocketHardening(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;
    Method display = class_getInstanceMethod(cls, NSSelectorFromString(@"startDisplayServer"));
    if (display) method_setImplementation(display, (IMP)JuiceSocketStartDisplay);
    Method control = class_getInstanceMethod(cls, NSSelectorFromString(@"startControlServer"));
    if (control) method_setImplementation(control, (IMP)JuiceSocketStartControl);
}
