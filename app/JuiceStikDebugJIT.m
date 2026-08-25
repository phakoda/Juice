#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <spawn.h>
#import <dlfcn.h>
#import <signal.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0u
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000u
#endif

/*
 * StikDebug JIT coordinator.
 *
 * Juice's JIT lives in the Wine/FEX process, not the UIKit host.  Interpose the
 * one posix_spawn used for the Grape trace parent, start that exact process
 * suspended, ask StikDebug to attach to its PID, and resume only after the
 * kernel reports CS_DEBUGGED.  This preserves the PID across the trace-parent
 * exec chain and prevents FEX's iOS 26 breakpoint protocol from running before
 * StikDebug's script is actually attached.
 */

typedef int (*JuicePosixSpawnFn)(pid_t *, const char *,
                                 const posix_spawn_file_actions_t *,
                                 const posix_spawnattr_t *,
                                 char *const [], char *const []);

typedef uint32_t JuiceIOObject;
typedef JuiceIOObject (*JuiceIORegistryEntryFromPathFn)(uint32_t, const char *);
typedef int (*JuiceIORegistryEntryCreateCFPropertiesFn)(JuiceIOObject, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t);
typedef int (*JuiceIOObjectReleaseFn)(JuiceIOObject);

typedef CFTypeRef (*JuiceSecTaskCreateFromSelfFn)(CFAllocatorRef);
typedef CFTypeRef (*JuiceSecTaskCopyValueForEntitlementFn)(CFTypeRef, CFStringRef, CFErrorRef *);
typedef int (*JuiceCSOpsFn)(pid_t, unsigned int, void *, size_t);

static JuicePosixSpawnFn JuiceRealPosixSpawn(void)
{
    static JuicePosixSpawnFn function;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        function = (JuicePosixSpawnFn)dlsym(RTLD_NEXT, "posix_spawn");
    });
    return function;
}

static BOOL JuiceHasEnvironmentFlag(char *const envp[], const char *prefix)
{
    if (!envp || !prefix) return NO;
    size_t length = strlen(prefix);
    for (size_t index = 0; envp[index]; ++index)
        if (!strncmp(envp[index], prefix, length)) return YES;
    return NO;
}

static BOOL JuiceIsFEXLaunch(const char *path, char *const envp[])
{
    if (!path) return NO;
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    if (strcmp(name, "grape-trace-parent")) return NO;
    return JuiceHasEnvironmentFlag(envp, "HODLL=libwow64fex.dll") ||
           JuiceHasEnvironmentFlag(envp, "HODLL64=libarm64ecfex.dll");
}

static BOOL JuiceStikDebugDisabled(char *const envp[])
{
    return JuiceHasEnvironmentFlag(envp, "JUICE_DISABLE_STIKDEBUG_JIT=1");
}

static BOOL JuiceTXMPresent(void)
{
    static NSInteger cached = -1;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        BOOL present = NO;
        BOOL resolved = NO;
        void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
        if (handle)
        {
            JuiceIORegistryEntryFromPathFn entryFromPath =
                (JuiceIORegistryEntryFromPathFn)dlsym(handle, "IORegistryEntryFromPath");
            JuiceIORegistryEntryCreateCFPropertiesFn createProperties =
                (JuiceIORegistryEntryCreateCFPropertiesFn)dlsym(handle, "IORegistryEntryCreateCFProperties");
            JuiceIOObjectReleaseFn releaseObject =
                (JuiceIOObjectReleaseFn)dlsym(handle, "IOObjectRelease");
            if (entryFromPath && createProperties && releaseObject)
            {
                JuiceIOObject entry = entryFromPath(0, "IODeviceTree:/chosen/memory-map");
                if (entry)
                {
                    CFMutableDictionaryRef properties = NULL;
                    if (createProperties(entry, &properties, kCFAllocatorDefault, 0) == 0 && properties)
                    {
                        present = CFDictionaryContainsKey(properties, CFSTR("TXM"));
                        resolved = YES;
                        CFRelease(properties);
                    }
                    releaseObject(entry);
                }
            }
            dlclose(handle);
        }

        /* If IOKit probing is unavailable, fail closed on iOS 26+: the
         * universal protocol is safe while the debugger script is attached,
         * whereas assuming TXM is absent can leave every FEX page non-executable. */
        if (!resolved)
        {
            NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
            present = version.majorVersion >= 26;
        }
        cached = present ? 1 : 0;
    });
    return cached == 1;
}

static BOOL JuiceHasGetTaskAllow(void)
{
    void *handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_LOCAL);
    if (!handle) return NO;
    JuiceSecTaskCreateFromSelfFn createTask =
        (JuiceSecTaskCreateFromSelfFn)dlsym(handle, "SecTaskCreateFromSelf");
    JuiceSecTaskCopyValueForEntitlementFn copyEntitlement =
        (JuiceSecTaskCopyValueForEntitlementFn)dlsym(handle, "SecTaskCopyValueForEntitlement");
    if (!createTask || !copyEntitlement)
    {
        dlclose(handle);
        return NO;
    }
    CFTypeRef task = createTask(kCFAllocatorDefault);
    CFTypeRef value = task ? copyEntitlement(task, CFSTR("get-task-allow"), NULL) : NULL;
    BOOL allowed = value == kCFBooleanTrue;
    if (value) CFRelease(value);
    if (task) CFRelease(task);
    dlclose(handle);
    return allowed;
}

static NSString *JuiceStikDebugScheme(void)
{
    __block NSString *scheme = nil;
    void (^check)(void) = ^{
        UIApplication *application = UIApplication.sharedApplication;
        if ([application canOpenURL:[NSURL URLWithString:@"stikdebug://"]]) scheme = @"stikdebug";
        else if ([application canOpenURL:[NSURL URLWithString:@"stikjit://"]]) scheme = @"stikjit";
    };
    if (NSThread.isMainThread) check();
    else dispatch_sync(dispatch_get_main_queue(), check);
    return scheme;
}

static BOOL JuiceRequestStikDebug(pid_t pid, NSString *scheme, BOOL txm)
{
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (!bundleID.length || !scheme.length || pid <= 0) return NO;

    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = scheme;
    components.host = @"enable-jit";
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithObjects:
        [NSURLQueryItem queryItemWithName:@"bundle-id" value:bundleID],
        [NSURLQueryItem queryItemWithName:@"pid" value:[NSString stringWithFormat:@"%d", pid]], nil];
    if (txm)
        [items addObject:[NSURLQueryItem queryItemWithName:@"script-name" value:@"universal.js"]];
    components.queryItems = items;
    NSURL *url = components.URL;
    if (!url) return NO;

    void (^openRequest)(void) = ^{
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
            fprintf(stderr, "STIKDEBUG_JIT_OPEN pid=%d scheme=%s txm=%d accepted=%d\n",
                    pid, scheme.UTF8String, txm, success);
            fflush(stderr);
        }];
    };
    if (NSThread.isMainThread) openRequest();
    else dispatch_async(dispatch_get_main_queue(), openRequest);
    return YES;
}

static BOOL JuiceProcessIsDebugged(pid_t pid)
{
    static JuiceCSOpsFn csopsFunction;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        csopsFunction = (JuiceCSOpsFn)dlsym(RTLD_DEFAULT, "csops");
    });
    if (!csopsFunction) return NO;
    uint32_t flags = 0;
    return csopsFunction(pid, CS_OPS_STATUS, &flags, sizeof(flags)) == 0 && (flags & CS_DEBUGGED) != 0;
}

static void JuiceResumeAfterStikDebug(pid_t pid)
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        /* Juice is normally suspended while StikDebug is foreground.  Use a
         * generous bound so that foreground suspension does not turn a normal
         * user round-trip into an accidental timeout. */
        const unsigned int pollUsec = 100000;
        const unsigned int maxPolls = 18000; /* 30 minutes of active wall time. */
        for (unsigned int poll = 0; poll < maxPolls; ++poll)
        {
            if (JuiceProcessIsDebugged(pid))
            {
                fprintf(stderr, "STIKDEBUG_JIT_READY pid=%d\n", pid);
                fflush(stderr);
                kill(pid, SIGCONT);
                return;
            }
            if (kill(pid, 0) != 0 && errno == ESRCH) return;
            usleep(pollUsec);
        }
        fprintf(stderr, "STIKDEBUG_JIT_TIMEOUT pid=%d\n", pid);
        fflush(stderr);
        kill(pid, SIGTERM);
    });
}

static char **JuiceCopyEnvironmentForJIT(char *const envp[], BOOL txm)
{
    size_t count = 0;
    while (envp && envp[count]) ++count;
    char **copy = calloc(count + 3, sizeof(char *));
    if (!copy) return NULL;
    for (size_t index = 0; index < count; ++index)
    {
        copy[index] = strdup(envp[index]);
        if (!copy[index])
        {
            for (size_t freeIndex = 0; freeIndex < index; ++freeIndex) free(copy[freeIndex]);
            free(copy);
            return NULL;
        }
    }
    copy[count] = strdup("JUICE_STIKDEBUG_JIT=1");
    copy[count + 1] = strdup(txm ? "JUICE_STIKDEBUG_TXM=1" : "JUICE_STIKDEBUG_TXM=0");
    if (!copy[count] || !copy[count + 1])
    {
        for (size_t index = 0; index < count + 2; ++index) free(copy[index]);
        free(copy);
        return NULL;
    }
    return copy;
}

static void JuiceFreeEnvironment(char **environment)
{
    if (!environment) return;
    for (size_t index = 0; environment[index]; ++index) free(environment[index]);
    free(environment);
}

static int JuiceSpawnSuspended(JuicePosixSpawnFn realSpawn, pid_t *pid, const char *path,
                               const posix_spawn_file_actions_t *actions,
                               const posix_spawnattr_t *sourceAttributes,
                               char *const argv[], char *const envp[])
{
#ifndef POSIX_SPAWN_START_SUSPENDED
    (void)pid; (void)path; (void)actions; (void)sourceAttributes; (void)argv; (void)envp;
    return ENOTSUP;
#else
    posix_spawnattr_t attributes;
    int result = posix_spawnattr_init(&attributes);
    if (result) return result;

    short flags = 0;
    if (sourceAttributes) posix_spawnattr_getflags(sourceAttributes, &flags);
    flags |= POSIX_SPAWN_START_SUSPENDED;
    result = posix_spawnattr_setflags(&attributes, flags);

    if (!result && sourceAttributes)
    {
        pid_t pgroup = 0;
        sigset_t mask, defaults;
        if (!posix_spawnattr_getpgroup(sourceAttributes, &pgroup))
            result = posix_spawnattr_setpgroup(&attributes, pgroup);
        if (!result && !posix_spawnattr_getsigmask(sourceAttributes, &mask))
            result = posix_spawnattr_setsigmask(&attributes, &mask);
        if (!result && !posix_spawnattr_getsigdefault(sourceAttributes, &defaults))
            result = posix_spawnattr_setsigdefault(&attributes, &defaults);
    }

    if (!result) result = realSpawn(pid, path, actions, &attributes, argv, envp);
    posix_spawnattr_destroy(&attributes);
    return result;
#endif
}

int posix_spawn(pid_t *pid, const char *path,
                const posix_spawn_file_actions_t *fileActions,
                const posix_spawnattr_t *attributes,
                char *const argv[], char *const envp[])
{
    JuicePosixSpawnFn realSpawn = JuiceRealPosixSpawn();
    if (!realSpawn) return ENOSYS;

    if (!JuiceIsFEXLaunch(path, envp) || JuiceStikDebugDisabled(envp))
        return realSpawn(pid, path, fileActions, attributes, argv, envp);

    NSString *scheme = JuiceStikDebugScheme();
    if (!scheme.length)
    {
        fprintf(stderr, "STIKDEBUG_JIT_UNAVAILABLE reason=scheme\n");
        fflush(stderr);
        return realSpawn(pid, path, fileActions, attributes, argv, envp);
    }
    if (!JuiceHasGetTaskAllow())
    {
        fprintf(stderr, "STIKDEBUG_JIT_UNAVAILABLE reason=get-task-allow\n");
        fflush(stderr);
        return EACCES;
    }

    BOOL txm = JuiceTXMPresent();
    char **jitEnvironment = JuiceCopyEnvironmentForJIT(envp, txm);
    if (!jitEnvironment) return ENOMEM;

    pid_t localPID = -1;
    pid_t *spawnPID = pid ? pid : &localPID;
    int result = JuiceSpawnSuspended(realSpawn, spawnPID, path, fileActions, attributes, argv, jitEnvironment);
    JuiceFreeEnvironment(jitEnvironment);
    if (result) return result;

    pid_t targetPID = *spawnPID;
    if (!JuiceRequestStikDebug(targetPID, scheme, txm))
    {
        kill(targetPID, SIGTERM);
        return EIO;
    }

    fprintf(stderr, "STIKDEBUG_JIT_REQUESTED pid=%d txm=%d script=%s\n",
            targetPID, txm, txm ? "universal.js" : "none");
    fflush(stderr);
    JuiceResumeAfterStikDebug(targetPID);
    return 0;
}
