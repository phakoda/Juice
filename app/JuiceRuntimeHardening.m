#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <signal.h>
#import <sys/resource.h>

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
 */

static IMP JuiceOriginalViewDidLoad;

static void JuiceRuntimeAppend(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
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
    SEL selector = NSSelectorFromString(@"viewDidLoad");
    if (!cls) return;

    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    JuiceOriginalViewDidLoad = method_setImplementation(method, (IMP)JuiceRuntimeViewDidLoad);
}
