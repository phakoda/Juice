#import <UIKit/UIKit.h>
#import <errno.h>
#import <fcntl.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>

static void (*JuiceOriginalLifecycleViewDidLoad)(id, SEL);
static char JuiceLifecycleTokensKey;
static char JuiceWasBackgroundedKey;

static id JuiceLifecycleValue(id object, NSString *key)
{
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceLifecycleSetValue(id object, NSString *key, id value)
{
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static void JuiceLifecycleAppend(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static BOOL JuiceDescriptorAlive(int fd)
{
    if (fd < 0) return NO;
    errno = 0;
    if (fcntl(fd, F_GETFD) >= 0) return YES;
    return errno != EBADF;
}

static BOOL JuiceListenerNeedsRestart(id self, NSString *fdKey, NSString *pathKey)
{
    int fd = [JuiceLifecycleValue(self, fdKey) intValue];
    NSString *path = JuiceLifecycleValue(self, pathKey);
    if (!JuiceDescriptorAlive(fd)) return YES;
    if (!path.length) return YES;
    return access(path.fileSystemRepresentation, F_OK) != 0;
}

static void JuiceRestartListenerIfNeeded(id self, NSString *fdKey, NSString *pathKey,
                                         NSString *selectorName, NSString *label)
{
    if (!JuiceListenerNeedsRestart(self, fdKey, pathKey)) return;

    int fd = [JuiceLifecycleValue(self, fdKey) intValue];
    if (JuiceDescriptorAlive(fd)) close(fd);
    JuiceLifecycleSetValue(self, fdKey, @(-1));

    NSString *oldPath = JuiceLifecycleValue(self, pathKey);
    if (oldPath.length) unlink(oldPath.fileSystemRepresentation);

    SEL selector = NSSelectorFromString(selectorName);
    if ([self respondsToSelector:selector])
    {
        JuiceLifecycleAppend(self, [NSString stringWithFormat:
            @"APP_LIFECYCLE listener_restart=%@ old_fd=%d old_path=%@\n",
            label, fd, oldPath ?: @""]);
        ((void (*)(id, SEL))objc_msgSend)(self, selector);
    }
}

static void JuiceEnteredBackground(id self)
{
    objc_setAssociatedObject(self, &JuiceWasBackgroundedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    /* UIKit normally sends touchesCancelled before suspension, but discard host
       capture bookkeeping as a final guard. A stale closed-client capture can
       otherwise redirect the first tap after a long suspension. */
    JuiceLifecycleSetValue(self, @"inputClient", @(-1));
    JuiceLifecycleSetValue(self, @"inputHwnd", @0);
    if ([self isKindOfClass:UIViewController.class])
        [((UIViewController *)self).view endEditing:YES];

    JuiceLifecycleAppend(self, [NSString stringWithFormat:
        @"APP_LIFECYCLE background child=%d server=%d display_fd=%d control_fd=%d\n",
        [JuiceLifecycleValue(self, @"child") intValue],
        [JuiceLifecycleValue(self, @"server") intValue],
        [JuiceLifecycleValue(self, @"listenFD") intValue],
        [JuiceLifecycleValue(self, @"controlListenFD") intValue]]);
}

static void JuiceEnteredForeground(id self)
{
    if (![objc_getAssociatedObject(self, &JuiceWasBackgroundedKey) boolValue]) return;
    objc_setAssociatedObject(self, &JuiceWasBackgroundedKey, @NO,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    JuiceRestartListenerIfNeeded(self, @"listenFD", @"socketPath",
                                 @"startDisplayServer", @"display");
    JuiceRestartListenerIfNeeded(self, @"controlListenFD", @"controlSocketPath",
                                 @"startControlServer", @"control");

    if ([JuiceLifecycleValue(self, @"experimentalMultiWindow") boolValue])
    {
        SEL composite = NSSelectorFromString(@"compositeWineDesktop");
        if ([self respondsToSelector:composite]) ((void (*)(id, SEL))objc_msgSend)(self, composite);
    }

    JuiceLifecycleAppend(self, [NSString stringWithFormat:
        @"APP_LIFECYCLE foreground display_fd=%d control_fd=%d clients=%lu\n",
        [JuiceLifecycleValue(self, @"listenFD") intValue],
        [JuiceLifecycleValue(self, @"controlListenFD") intValue],
        (unsigned long)[JuiceLifecycleValue(self, @"clients") count]]);
}

static void JuiceWillTerminate(id self)
{
    NSArray<NSString *> *fdKeys = @[@"listenFD", @"controlListenFD"];
    NSArray<NSString *> *pathKeys = @[@"socketPath", @"controlSocketPath"];
    for (NSUInteger index = 0; index < fdKeys.count; index++)
    {
        int fd = [JuiceLifecycleValue(self, fdKeys[index]) intValue];
        if (JuiceDescriptorAlive(fd)) close(fd);
        JuiceLifecycleSetValue(self, fdKeys[index], @(-1));
        NSString *path = JuiceLifecycleValue(self, pathKeys[index]);
        if (path.length) unlink(path.fileSystemRepresentation);
    }
    JuiceLifecycleAppend(self, @"APP_LIFECYCLE terminate listeners_closed=1\n");
}

static void JuiceLifecycleViewDidLoad(id self, SEL _cmd)
{
    if (JuiceOriginalLifecycleViewDidLoad) JuiceOriginalLifecycleViewDidLoad(self, _cmd);

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    __weak id weakSelf = self;
    id background = [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                                         object:nil queue:NSOperationQueue.mainQueue
                                    usingBlock:^(__unused NSNotification *note) {
        id strongSelf = weakSelf;
        if (strongSelf) JuiceEnteredBackground(strongSelf);
    }];
    id foreground = [center addObserverForName:UIApplicationWillEnterForegroundNotification
                                         object:nil queue:NSOperationQueue.mainQueue
                                    usingBlock:^(__unused NSNotification *note) {
        id strongSelf = weakSelf;
        if (strongSelf) JuiceEnteredForeground(strongSelf);
    }];
    id terminate = [center addObserverForName:UIApplicationWillTerminateNotification
                                        object:nil queue:NSOperationQueue.mainQueue
                                   usingBlock:^(__unused NSNotification *note) {
        id strongSelf = weakSelf;
        if (strongSelf) JuiceWillTerminate(strongSelf);
    }];
    objc_setAssociatedObject(self, &JuiceLifecycleTokensKey,
                             @[background, foreground, terminate],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

__attribute__((constructor(425)))
static void JuiceInstallAppLifecycleHardening(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;
    Method view = class_getInstanceMethod(cls, NSSelectorFromString(@"viewDidLoad"));
    if (view)
        JuiceOriginalLifecycleViewDidLoad = (void (*)(id, SEL))
            method_setImplementation(view, (IMP)JuiceLifecycleViewDidLoad);
}
