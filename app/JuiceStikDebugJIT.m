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
#ifndef POSIX_SPAWN_START_SUSPENDED
/* Darwin's spawn extension is present on supported devices even when an older
 * public SDK does not expose the constant in spawn.h. */
#define POSIX_SPAWN_START_SUSPENDED 0x0080
#endif

/*
 * StikDebug JIT coordinator.
 *
 * Juice's JIT lives in the Wine/FEX process, not the UIKit host. Interpose the
 * one posix_spawn used for the Grape trace parent, start that exact process
 * suspended, ask StikDebug to attach to its PID with the universal script, and
 * resume only after the kernel reports CS_DEBUGGED. This preserves the PID
 * across the trace-parent exec chain and prevents FEX's breakpoint protocol
 * from running before StikDebug's script is actually attached.
 */

typedef int (*JuicePosixSpawnFn)(pid_t *, const char *,
                                 const posix_spawn_file_actions_t *,
                                 const posix_spawnattr_t *,
                                 char *const [], char *const []);
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

static BOOL JuiceHasEnvironmentEntry(char *const envp[], const char *entry)
{
    if (!envp || !entry) return NO;
    for (size_t index = 0; envp[index]; ++index)
        if (!strcmp(envp[index], entry)) return YES;
    return NO;
}

static BOOL JuiceIsFEXLaunch(const char *path, char *const envp[])
{
    if (!path) return NO;
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    if (strcmp(name, "grape-trace-parent")) return NO;
    return JuiceHasEnvironmentEntry(envp, "HODLL=libwow64fex.dll") ||
           JuiceHasEnvironmentEntry(envp, "HODLL64=libarm64ecfex.dll");
}

static BOOL JuiceStikDebugDisabled(char *const envp[])
{
    return JuiceHasEnvironmentEntry(envp, "JUICE_DISABLE_STIKDEBUG_JIT=1");
}

/* MeloNX detects TXM from the same preboot firmware marker. Keep that exact
 * signal as the primary check; only use the OS-major fallback if preboot is not
 * readable from the current installation. */
static NSString *JuiceFirstEntryOfLength(NSString *directory, NSUInteger length)
{
    NSError *error = nil;
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:&error];
    if (!entries) return nil;
    for (NSString *entry in entries)
        if (entry.length == length) return [directory stringByAppendingPathComponent:entry];
    return nil;
}

static BOOL JuiceTXMPresent(void)
{
    static NSInteger cached = -1;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        BOOL resolved = NO;
        BOOL present = NO;
        NSString *firmware = nil;

        NSString *bootUUID = JuiceFirstEntryOfLength(@"/System/Volumes/Preboot", 36);
        if (bootUUID)
        {
            NSString *boot = [bootUUID stringByAppendingPathComponent:@"boot"];
            NSString *manifest = JuiceFirstEntryOfLength(boot, 96);
            if (manifest)
                firmware = [manifest stringByAppendingPathComponent:@"usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4"];
        }
        if (!firmware)
        {
            NSString *manifest = JuiceFirstEntryOfLength(@"/private/preboot", 96);
            if (manifest)
                firmware = [manifest stringByAppendingPathComponent:@"usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4"];
        }

        if (firmware)
        {
            resolved = YES;
            present = access(firmware.fileSystemRepresentation, F_OK) == 0;
        }

        /* Failing closed is safer than attempting the legacy executable-memory
         * path on a TXM device. The universal StikDebug script is selected for
         * every launch either way. */
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
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"bundle-id" value:bundleID],
        [NSURLQueryItem queryItemWithName:@"pid" value:[NSString stringWithFormat:@"%d", pid]],
        [NSURLQueryItem queryItemWithName:@"script-name" value:@"universal.js"]
    ];
    NSURL *url = components.URL;
    if (!url) return NO;

    void (^openRequest)(void) = ^{
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
            fprintf(stderr, "STIKDEBUG_JIT_OPEN pid=%d scheme=%s txm=%d accepted=%d\n",
                    pid, scheme.UTF8String, txm, success);
            fflush(stderr);
            if (!success)
            {
                /* The child was intentionally born suspended. Never strand it
                 * if iOS rejects the StikDebug handoff. */
                kill(pid, SIGTERM);
            }
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
        /* Juice is normally suspended while StikDebug is foreground. Use a
         * generous bound so foreground suspension does not turn a normal user
         * round-trip into an accidental timeout. */
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
        struct sched_param schedulingParameters;
        int schedulingPolicy = 0;
        if (!posix_spawnattr_getpgroup(sourceAttributes, &pgroup))
            result = posix_spawnattr_setpgroup(&attributes, pgroup);
        if (!result && !posix_spawnattr_getsigmask(sourceAttributes, &mask))
            result = posix_spawnattr_setsigmask(&attributes, &mask);
        if (!result && !posix_spawnattr_getsigdefault(sourceAttributes, &defaults))
            result = posix_spawnattr_setsigdefault(&attributes, &defaults);
        if (!result && !posix_spawnattr_getschedparam(sourceAttributes, &schedulingParameters))
            result = posix_spawnattr_setschedparam(&attributes, &schedulingParameters);
        if (!result && !posix_spawnattr_getschedpolicy(sourceAttributes, &schedulingPolicy))
            result = posix_spawnattr_setschedpolicy(&attributes, schedulingPolicy);
    }

    if (!result) result = realSpawn(pid, path, actions, &attributes, argv, envp);
    posix_spawnattr_destroy(&attributes);
    return result;
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
        return ENOENT;
    }
    if (!JuiceHasGetTaskAllow())
    {
        /* The packaged Wine child is independently signed with get-task-allow;
         * this host-side check catches a mismatched Juice installation before
         * starting a child that StikDebug cannot service. */
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

    fprintf(stderr, "STIKDEBUG_JIT_REQUESTED pid=%d txm=%d script=universal.js\n", targetPID, txm);
    fflush(stderr);
    JuiceResumeAfterStikDebug(targetPID);
    return 0;
}
