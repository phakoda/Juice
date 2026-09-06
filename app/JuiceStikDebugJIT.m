#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <signal.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "JuiceStikDebugJIT.h"
#import "JuiceJITState.h"
#import "JuiceJITAck.h"

#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0u
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000u
#endif
#ifndef POSIX_SPAWN_START_SUSPENDED
#define POSIX_SPAWN_START_SUSPENDED 0x0080
#endif

typedef int (*JuicePosixSpawnFn)(pid_t *, const char *,
    const posix_spawn_file_actions_t *, const posix_spawnattr_t *,
    char *const [], char *const []);
typedef CFTypeRef (*JuiceSecTaskCreateFromSelfFn)(CFAllocatorRef);
typedef CFTypeRef (*JuiceSecTaskCopyValueForEntitlementFn)(CFTypeRef, CFStringRef, CFErrorRef *);
typedef int (*JuiceCSOpsFn)(pid_t, unsigned int, void *, size_t);

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
    /* Preserve existing translated launches unless this experimental backend
     * is explicitly selected in the child environment. */
    return !JuiceHasEnvironmentEntry(envp, "JUICE_ENABLE_STIKDEBUG_JIT=1") ||
           JuiceHasEnvironmentEntry(envp, "JUICE_DISABLE_STIKDEBUG_JIT=1");
}

/* MeloNX detects TXM from the same preboot firmware marker. Keep that exact
 * signal as the primary check; require the protected-memory protocol if preboot is not
 * readable. OS-major version alone does not identify the SoC security mode. */
static NSString *JuiceFirstEntryOfLength(NSString *directory, NSUInteger length)
{
    NSError *error = nil;
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:&error];
    if (!entries) return nil;
    for (NSString *entry in entries)
        if (entry.length == length) return [directory stringByAppendingPathComponent:entry];
    return nil;
}

static BOOL JuiceUseTXMProtocol(void)
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
            int result = access(firmware.fileSystemRepresentation, F_OK);
            resolved = result == 0 || errno == ENOENT;
            present = result == 0;
        }

        /* Failing closed is safer than attempting the legacy executable-memory
         * path on a TXM device. The universal StikDebug script is selected for
         * every launch either way. */
        if (!resolved)
        {
            present = YES;
            fprintf(stderr, "STIKDEBUG_JIT_TXM_UNKNOWN protected_protocol_required=1\n");
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

static int JuiceSpawnSuspended(JuicePosixSpawnFn realSpawn, pid_t *pid, const char *path,
                               const posix_spawn_file_actions_t *actions,
                               const posix_spawnattr_t *sourceAttributes,
                               char *const argv[], char *const envp[])
{
    posix_spawnattr_t attributes;
    int result = posix_spawnattr_init(&attributes);
    if (result) return result;

    short flags = 0;
    if (sourceAttributes) result = posix_spawnattr_getflags(sourceAttributes, &flags);
    flags |= POSIX_SPAWN_START_SUSPENDED;
    if (!result) result = posix_spawnattr_setflags(&attributes, flags);

    /* iPhoneOS does not expose the POSIX spawn scheduling-parameter APIs.
     * Copy only attributes requested by the supported spawn flags and propagate
     * getter errors instead of silently spawning with default values. */
    if (!result && sourceAttributes && (flags & POSIX_SPAWN_SETPGROUP))
    {
        pid_t pgroup = 0;
        result = posix_spawnattr_getpgroup(sourceAttributes, &pgroup);
        if (!result) result = posix_spawnattr_setpgroup(&attributes, pgroup);
    }
    if (!result && sourceAttributes && (flags & POSIX_SPAWN_SETSIGMASK))
    {
        sigset_t mask;
        result = posix_spawnattr_getsigmask(sourceAttributes, &mask);
        if (!result) result = posix_spawnattr_setsigmask(&attributes, &mask);
    }
    if (!result && sourceAttributes && (flags & POSIX_SPAWN_SETSIGDEF))
    {
        sigset_t defaults;
        result = posix_spawnattr_getsigdefault(sourceAttributes, &defaults);
        if (!result) result = posix_spawnattr_setsigdefault(&attributes, &defaults);
    }

    if (!result) result = realSpawn(pid, path, actions, &attributes, argv, envp);
    posix_spawnattr_destroy(&attributes);
    return result;
}

@interface JuiceJITSession : NSObject
@property(nonatomic,weak) id owner;
@property(nonatomic) pid_t pid;
@property(nonatomic) uint64_t generation;
@property(nonatomic) JuiceJITState state;
@property(nonatomic) JuiceJITAck acknowledgement;
@property(nonatomic,copy) NSString *nonce;
@property(nonatomic,strong) NSURL *url;
@property(nonatomic,strong) dispatch_source_t timer;
@property(nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@end
@implementation JuiceJITSession
@end
static char JuiceJITSessionKey;
static void (*JuiceOriginalJITStop)(id,SEL,NSString *);

static uint64_t JuiceJITNowMS(void)
{
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    /* Continuous time includes suspension and system sleep. */
    return (uint64_t)((long double)mach_continuous_time()*base.numer/base.denom/1000000.0L);
}
static id JuiceJITValue(id owner,NSString *key)
{
    @try{return [owner valueForKey:key];}@catch(__unused NSException *error){return nil;}
}
static BOOL JuiceJITOwnsChild(JuiceJITSession *session)
{
    dispatch_assert_queue(dispatch_get_main_queue());
    id owner=session.owner;
    return owner && objc_getAssociatedObject(owner,&JuiceJITSessionKey)==session &&
        session.pid>0 && [JuiceJITValue(owner,@"child") intValue]==session.pid &&
        [JuiceJITValue(owner,@"launchGeneration") unsignedLongLongValue]==session.generation;
}
static void JuiceJITDispose(JuiceJITSession *session)
{
    if(session.timer){dispatch_source_cancel(session.timer);session.timer=nil;}
    if(session.backgroundTask!=UIBackgroundTaskInvalid)
    {
        UIBackgroundTaskIdentifier task=session.backgroundTask;
        session.backgroundTask=UIBackgroundTaskInvalid;
        [UIApplication.sharedApplication endBackgroundTask:task];
    }
    id owner=session.owner;
    if(owner && objc_getAssociatedObject(owner,&JuiceJITSessionKey)==session)
        objc_setAssociatedObject(owner,&JuiceJITSessionKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void JuiceJITEventReceived(JuiceJITSession *session,JuiceJITEvent event)
{
    dispatch_assert_queue(dispatch_get_main_queue());
    if(!session)return;
    BOOL owns=JuiceJITOwnsChild(session);
    JuiceJITState state=session.state;
    JuiceJITAction action=JuiceJITTransition(&state,event,JuiceJITNowMS(),owns,
        UIApplication.sharedApplication.applicationState==UIApplicationStateActive);
    session.state=state;
    if(action==JuiceJITResume)
    {
        /* No waitpid or owner mutation can interleave this ownership check
         * with the signal. An unreaped child reserves the numeric PID. */
        if(kill(session.pid,SIGCONT))
        {
            state.phase=JuiceJITFailed;session.state=state;action=JuiceJITStop;
        }
        else fprintf(stderr,"STIKDEBUG_JIT_RESUMED pid=%d runtime_ready=0\n",session.pid);
    }
    if(!JuiceJITPending(state))
    {
        id owner=session.owner;
        fprintf(stderr,"STIKDEBUG_JIT_FINISHED pid=%d phase=%d owned=%d\n",session.pid,state.phase,owns);
        JuiceJITDispose(session);
        if(action==JuiceJITStop && owns)
            ((void(*)(id,SEL,id))objc_msgSend)(owner,NSSelectorFromString(@"stopAllWineProcesses:"),@"stikdebug-handoff-failed");
    }
}
static void JuiceJITHardenedStop(id owner,SEL selector,NSString *reason)
{
    dispatch_assert_queue(dispatch_get_main_queue());
    JuiceJITSession *session=objc_getAssociatedObject(owner,&JuiceJITSessionKey);
    if([reason isEqualToString:@"application-will-resign-active"] && session &&
       JuiceJITOwnsChild(session) && JuiceJITPending(session.state) &&
       JuiceJITNowMS()<session.state.deadlineMS)
    {
        fprintf(stderr,"STIKDEBUG_JIT_HANDOFF pid=%d bounded=1\n",session.pid);
        return;
    }
    if(session){JuiceJITEventReceived(session,JuiceJITCancel);JuiceJITDispose(session);}
    if(JuiceOriginalJITStop)JuiceOriginalJITStop(owner,selector,reason);
}
static char **JuiceJITEnvironment(char *const envp[],BOOL txm,NSString *nonce)
{
    NSMutableArray<NSString *> *values=[NSMutableArray array];
    for(size_t i=0;envp && envp[i];i++)
    {
        NSString *entry=[NSString stringWithUTF8String:envp[i]];
        if(!entry)return NULL;
        if([entry hasPrefix:@"JUICE_STIKDEBUG_JIT="] || [entry hasPrefix:@"JUICE_STIKDEBUG_TXM="] ||
           [entry hasPrefix:@"JUICE_STIKDEBUG_SESSION="] || [entry hasPrefix:@"JUICE_EXTERNAL_DEBUG_EXEC="])continue;
        [values addObject:entry];
    }
    [values addObject:@"JUICE_STIKDEBUG_JIT=1"];
    [values addObject:txm?@"JUICE_STIKDEBUG_TXM=1":@"JUICE_STIKDEBUG_TXM=0"];
    [values addObject:@"JUICE_EXTERNAL_DEBUG_EXEC=1"];
    [values addObject:[@"JUICE_STIKDEBUG_SESSION=" stringByAppendingString:nonce]];
    char **copy=calloc(values.count+1,sizeof(*copy));
    if(!copy)return NULL;
    for(NSUInteger i=0;i<values.count;i++)
        if(!(copy[i]=strdup(values[i].UTF8String)))
        {for(NSUInteger j=0;j<i;j++)free(copy[j]);free(copy);return NULL;}
    return copy;
}
int JuiceSpawnForLaunch(id owner,pid_t *pid,const char *path,
    const posix_spawn_file_actions_t *actions,const posix_spawnattr_t *attributes,
    char *const argv[],char *const envp[])
{
    dispatch_assert_queue(dispatch_get_main_queue());
    if(!JuiceIsFEXLaunch(path,envp) || JuiceStikDebugDisabled(envp))
        return posix_spawn(pid,path,actions,attributes,argv,envp);
    if(!owner || !pid || objc_getAssociatedObject(owner,&JuiceJITSessionKey))return EINVAL;
    NSString *scheme=JuiceStikDebugScheme();
    if(!scheme.length)return ENOENT;
    if(!JuiceHasGetTaskAllow())return EACCES;
    if(!NSBundle.mainBundle.bundleIdentifier.length)return EINVAL;
    JuiceJITSession *session=[JuiceJITSession new];
    session.owner=owner;session.nonce=NSUUID.UUID.UUIDString;
    session.backgroundTask=UIBackgroundTaskInvalid;
    char **environment=JuiceJITEnvironment(envp,JuiceUseTXMProtocol(),session.nonce);
    if(!environment)return ENOMEM;
    int result=JuiceSpawnSuspended(posix_spawn,pid,path,actions,attributes,argv,environment);
    for(size_t i=0;environment[i];i++)free(environment[i]);free(environment);
    if(result)return result;
    session.pid=*pid;
    session.state=(JuiceJITState){.phase=JuiceJITOpening,.deadlineMS=JuiceJITNowMS()+120000};
    NSString *marker=[NSString stringWithFormat:@"JUICE_JIT_RUNTIME_READY pid=%d session=%@",*pid,session.nonce];
    NSData *markerBytes=[marker dataUsingEncoding:NSUTF8StringEncoding];
    JuiceJITAck acknowledgement;
    BOOL markerValid=JuiceJITAckInit(&acknowledgement,markerBytes.bytes,markerBytes.length);
    session.acknowledgement=acknowledgement;
    NSURLComponents *url=[NSURLComponents new];url.scheme=scheme;url.host=@"enable-jit";
    url.queryItems=@[
        [NSURLQueryItem queryItemWithName:@"bundle-id" value:NSBundle.mainBundle.bundleIdentifier],
        [NSURLQueryItem queryItemWithName:@"pid" value:[NSString stringWithFormat:@"%d",*pid]],
        [NSURLQueryItem queryItemWithName:@"script-name" value:@"universal.js"]];
    session.url=markerValid?url.URL:nil;
    objc_setAssociatedObject(owner,&JuiceJITSessionKey,session,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    /* Never return an error after spawn succeeds. The caller first adopts the
     * child, installs its pipe/reaper owner, then calls JuiceJITAdoptLaunch. */
    return 0;
}
void JuiceJITAdoptLaunch(id owner,pid_t pid,uint64_t generation)
{
    dispatch_assert_queue(dispatch_get_main_queue());
    JuiceJITSession *session=objc_getAssociatedObject(owner,&JuiceJITSessionKey);
    if(!session || session.pid!=pid)return;
    session.generation=generation;
    if(!session.url){JuiceJITEventReceived(session,JuiceJITOpenRejected);return;}
    __weak JuiceJITSession *weakSession=session;
    session.backgroundTask=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"Juice debugger handoff" expirationHandler:^{
        dispatch_async(dispatch_get_main_queue(),^{JuiceJITEventReceived(weakSession,JuiceJITOpenRejected);});
    }];
    /* Do not leave an externally suspended child without cleanup time. */
    if(session.backgroundTask==UIBackgroundTaskInvalid)
    {JuiceJITEventReceived(session,JuiceJITOpenRejected);return;}
    session.timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    if(!session.timer){JuiceJITEventReceived(session,JuiceJITOpenRejected);return;}
    dispatch_source_set_timer(session.timer,dispatch_time(DISPATCH_TIME_NOW,0),100*NSEC_PER_MSEC,10*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(session.timer,^{
        JuiceJITSession *current=weakSession;
        if(!current)return;
        JuiceJITEventReceived(current,JuiceJITTick);
        if(JuiceJITOwnsChild(current) && JuiceJITPending(current.state) && JuiceProcessIsDebugged(current.pid))
            JuiceJITEventReceived(current,JuiceJITDebugged);
    });
    dispatch_resume(session.timer);
    [UIApplication.sharedApplication openURL:session.url options:@{} completionHandler:^(BOOL success){
        dispatch_async(dispatch_get_main_queue(),^{JuiceJITEventReceived(weakSession,
            success?JuiceJITOpenAccepted:JuiceJITOpenRejected);});
    }];
}
void JuiceJITObserveOutput(id owner,pid_t pid,uint64_t generation,NSString *line)
{
    if(!line.length)return;
    dispatch_async(dispatch_get_main_queue(),^{
        JuiceJITSession *session=objc_getAssociatedObject(owner,&JuiceJITSessionKey);
        if(!session || session.pid!=pid || session.generation!=generation ||
           !JuiceJITOwnsChild(session) || !JuiceJITPending(session.state))return;
        NSData *bytes=[line dataUsingEncoding:NSUTF8StringEncoding];
        JuiceJITAck acknowledgement=session.acknowledgement;
        BOOL ready=JuiceJITAckFeed(&acknowledgement,bytes.bytes,bytes.length);
        session.acknowledgement=acknowledgement;
        if(ready)JuiceJITEventReceived(session,JuiceJITRuntimeAck);
    });
}
void JuiceJITWillReap(id owner,pid_t pid,uint64_t generation)
{
    dispatch_assert_queue(dispatch_get_main_queue());
    JuiceJITSession *session=objc_getAssociatedObject(owner,&JuiceJITSessionKey);
    if(session && session.pid==pid && session.generation==generation)
    {JuiceJITEventReceived(session,JuiceJITCancel);JuiceJITDispose(session);}
}
__attribute__((constructor(460)))
static void JuiceInstallJITOwnership(void)
{
    Class cls=NSClassFromString(@"JuiceController");
    Method method=class_getInstanceMethod(cls,NSSelectorFromString(@"stopAllWineProcesses:"));
    if(method)JuiceOriginalJITStop=(void*)method_setImplementation(method,(IMP)JuiceJITHardenedStop);
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillTerminateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){
        id owner=UIApplication.sharedApplication.keyWindow.rootViewController;
        SEL stop=NSSelectorFromString(@"stopAllWineProcesses:");
        if([owner respondsToSelector:stop])((void(*)(id,SEL,id))objc_msgSend)(owner,stop,@"application-terminate");
    }];
}
