#import "JuiceSideStoreRuntime.h"
#import "JuiceRuntimePreflight.h"
#import "JuiceAppProfile.h"
#import "JuiceUTF8Stream.h"
#import "../runtime/embedded/JuiceEmbeddedRuntime.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import <sys/sysctl.h>
#import <unistd.h>

/* This file is compiled only into the ordinary-development-signing target.
 * The legacy child coordinator is not linked into that executable. */
static char CoordinatorKey;
static BOOL RuntimeActive;
static id Value(id owner, NSString *key) { @try { return [owner valueForKey:key]; } @catch (__unused NSException *e) { return nil; } }
static void Set(id owner, NSString *key, id value) { @try { [owner setValue:value forKey:key]; } @catch (__unused NSException *e) {} }
static id Call(id owner, NSString *name)
{
    SEL selector = NSSelectorFromString(name);
    return [owner respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(owner, selector) : nil;
}
static void CallVoid(id owner, NSString *name)
{
    SEL selector = NSSelectorFromString(name);
    if ([owner respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(owner, selector);
}
static void Log(id owner, NSString *message)
{
    static _Atomic unsigned queued;
    unsigned previous = atomic_fetch_add(&queued, 1);
    if (previous >= 32) { atomic_fetch_sub(&queued, 1); return; }
    NSString *bounded = message.length <= 16384 ? message : [message substringToIndex:16384];
    dispatch_async(dispatch_get_main_queue(), ^{
        SEL selector = NSSelectorFromString(@"append:");
        if ([owner respondsToSelector:selector]) ((void (*)(id, SEL, id))objc_msgSend)(owner, selector, bounded);
        atomic_fetch_sub(&queued, 1);
    });
}
static void Alert(id owner, NSString *title, NSString *message)
{
    if (![owner isKindOfClass:UIViewController.class]) return;
    UIViewController *presenter = owner;
    if (presenter.presentedViewController) {
        Log(owner, [NSString stringWithFormat:@"%@: %@\n", title, message]);
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}
static BOOL Entitled(void)
{
    CFTypeRef (*create)(CFAllocatorRef) = dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CFTypeRef (*copy)(CFTypeRef, CFStringRef, CFErrorRef *) = dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!create || !copy) return NO;
    CFTypeRef task = create(kCFAllocatorDefault);
    if (!task) return NO;
    CFTypeRef value = copy(task, CFSTR("get-task-allow"), NULL);
    BOOL valid = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
    if (value) CFRelease(value);
    CFRelease(task);
    return valid;
}
static BOOL Debugged(BOOL requireAttached)
{
    int (*csopsFunction)(pid_t, unsigned int, void *, size_t) = dlsym(RTLD_DEFAULT, "csops");
    unsigned int flags = 0;
    if (!csopsFunction || csopsFunction(getpid(), 0, &flags, sizeof(flags)) || !(flags & 0x10000000u)) return NO;
    if (!requireAttached) return YES;
    struct kinfo_proc info = {0}; size_t length = sizeof(info);
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    return sysctl(mib, 4, &info, &length, NULL, 0) == 0 && length == sizeof(info) && (info.kp_proc.p_flag & P_TRACED);
}
static int TXMPresence(void)
{
    uint32_t (*entryFromPath)(uint32_t, const char *) = dlsym(RTLD_DEFAULT, "IORegistryEntryFromPath");
    CFTypeRef (*copyProperty)(uint32_t, CFStringRef, CFAllocatorRef, uint32_t) = dlsym(RTLD_DEFAULT, "IORegistryEntryCreateCFProperty");
    int (*releaseObject)(uint32_t) = dlsym(RTLD_DEFAULT, "IOObjectRelease");
    if (!entryFromPath || !copyProperty || !releaseObject) return -1;
    uint32_t entry = entryFromPath(0, "IODeviceTree:/chosen/memory-map");
    if (!entry) return -1;
    CFTypeRef keys = copyProperty(entry, CFSTR("IORegistryEntryPropertyKeys"), kCFAllocatorDefault, 0);
    releaseObject(entry);
    int result = -1;
    if (keys && CFGetTypeID(keys) == CFArrayGetTypeID())
        result = CFArrayContainsValue(keys, CFRangeMake(0, CFArrayGetCount(keys)), CFSTR("TXM")) ? 1 : 0;
    if (keys) CFRelease(keys);
    return result;
}
static uint64_t ClockNanos(void)
{
    static mach_timebase_info_data_t timebase; static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&timebase); });
    return (uint64_t)((__uint128_t)mach_continuous_time() * timebase.numer / timebase.denom);
}
NSArray<NSString *> *JuiceSideStoreParseArguments(NSString *line, NSString **error)
{
    if ([line lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 65536) { if (error) *error = @"Arguments exceed 64 KiB."; return nil; }
    NSMutableArray *values = [NSMutableArray array]; NSMutableString *part = [NSMutableString string];
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    unichar quote = 0; BOOL started = NO;
    for (NSUInteger i = 0; i < line.length; ++i) {
        unichar c = [line characterAtIndex:i];
        if (!c) { if (error) *error = @"Arguments cannot contain a NUL character."; return nil; }
        if (quote) {
            if (c == quote) {
                if (i + 1 < line.length && [line characterAtIndex:i + 1] == quote) { [part appendFormat:@"%C", c]; ++i; }
                else quote = 0;
            } else [part appendFormat:@"%C", c];
            started = YES;
        } else if (c == '\'' || c == '"') { quote = c; started = YES; }
        else if ([whitespace characterIsMember:c]) {
            if (started) { [values addObject:[part copy]]; [part setString:@""]; started = NO; }
        } else { [part appendFormat:@"%C", c]; started = YES; }
    }
    if (quote || values.count > 253) { if (error) *error = @"Unterminated quote or too many arguments."; return nil; }
    if (started) [values addObject:[part copy]];
    return values;
}
static char **CopyStrings(NSArray<NSString *> *values)
{
    if (values.count > 512) return NULL;
    char **result = calloc(values.count + 1, sizeof(char *));
    if (!result) return NULL;
    for (NSUInteger i = 0; i < values.count; ++i) {
        const char *text = values[i].UTF8String;
        if (!text || strlen(text) != [values[i] lengthOfBytesUsingEncoding:NSUTF8StringEncoding] || !(result[i] = strdup(text))) {
            for (NSUInteger j = 0; j < i; ++j) free(result[j]); free(result); return NULL;
        }
    }
    return result;
}
static void FreeStrings(char **values) { if (values) { for (size_t i = 0; values[i]; ++i) free(values[i]); free(values); } }

@interface JuiceSideStoreCoordinator : NSObject
@property(nonatomic, weak) id owner;
@property(nonatomic, strong) UIButton *button;
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic) UIBackgroundTaskIdentifier background;
@property(nonatomic) uint64_t generation, deadline;
@property(nonatomic) BOOL opening, accepted, preparing, cancelled, starting;
@property(nonatomic) BOOL universal;
@property(nonatomic, copy) NSString *nonce;
@property(nonatomic, copy) NSDictionary *pending;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSFileHandle *outputReader;
- (void)enable;
- (void)beginHandoff:(BOOL)universal;
- (void)launch;
- (void)stop:(NSString *)reason;
- (void)tryStart;
- (void)finishHandoff:(NSString *)failure;
@end

static void RuntimeNotification(void *context, int event, int code, const char *message)
{
    JuiceSideStoreCoordinator *coordinator = (__bridge JuiceSideStoreCoordinator *)context;
    NSString *detail = message ? [NSString stringWithUTF8String:message] : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        Log(coordinator.owner, [NSString stringWithFormat:@"SIDESTORE_RUNTIME_EVENT event=%d code=%d %@\n", event, code, detail]);
        if (event == JUICE_RUNTIME_EXITED || event == JUICE_RUNTIME_FAILED) {
            RuntimeActive = NO;
            int fd = [Value(coordinator.owner, @"childInput") intValue];
            if (fd >= 0) { close(fd); Set(coordinator.owner, @"childInput", @(-1)); }
            [coordinator.button setTitle:@"Session ended — reopen Juice" forState:UIControlStateNormal];
        }
    });
}

@implementation JuiceSideStoreCoordinator
- (instancetype)init
{
    if (!(self = [super init])) return nil;
    _background = UIBackgroundTaskInvalid;
    _queue = dispatch_queue_create("org.juice.sidestore.runtime", DISPATCH_QUEUE_SERIAL);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(foreground:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    return self;
}
- (void)foreground:(NSNotification *)notification { (void)notification; [self tryStart]; }
- (void)enable
{
    NSAssert(NSThread.isMainThread, @"JIT requests are main-queue owned");
    if (juice_runtime_jit_ready()) {
        [self.button setTitle:@"JIT ready — Juice app process" forState:UIControlStateNormal];
        [self tryStart]; return;
    }
    if (self.opening || self.preparing || self.starting) return;
    if (!Entitled()) {
        self.pending = nil;
        Alert(self.owner, @"StikDebug cannot attach to this installation",
              @"The installed Juice executable does not have get-task-allow. Install this SideStore build using SideStore's development signing. A distribution or enterprise certificate cannot grant debugger access. Juice checks the installed signature, not merely the IPA's requested entitlements.");
        return;
    }
    int presence = TXMPresence();
    if (presence >= 0) { [self beginHandoff:presence == 1]; return; }
    UIAlertController *choice = [UIAlertController alertControllerWithTitle:@"Choose the StikDebug protocol"
        message:@"iOS did not expose TXM detection. On iOS 26 with protected executable memory, use universal.js. On older systems where attach/detach enables JIT, choose debugger attach. Juice still verifies authorization and executable memory before launching Wine."
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [choice addAction:[UIAlertAction actionWithTitle:@"Use universal.js" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf beginHandoff:YES]; }]];
    [choice addAction:[UIAlertAction actionWithTitle:@"Debugger attach / detach" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf beginHandoff:NO]; }]];
    [choice addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
        handler:^(__unused UIAlertAction *action) { weakSelf.pending = nil; }]];
    if ([self.owner isKindOfClass:UIViewController.class] && ![(UIViewController *)self.owner presentedViewController])
        [(UIViewController *)self.owner presentViewController:choice animated:YES completion:nil];
}
- (void)beginHandoff:(BOOL)universal
{
    if (self.opening || self.preparing || !Entitled() || !NSBundle.mainBundle.bundleIdentifier.length) return;
    UIApplication *app = UIApplication.sharedApplication;
    NSString *scheme = [app canOpenURL:[NSURL URLWithString:@"stikdebug://"]] ? @"stikdebug" :
        [app canOpenURL:[NSURL URLWithString:@"stikjit://"]] ? @"stikjit" : nil;
    if (!scheme) {
        self.pending = nil;
        Alert(self.owner, @"StikDebug is required", @"Install and configure StikDebug, its pairing file, and the loopback VPN first.");
        return;
    }
    self.cancelled = NO; self.accepted = NO; self.universal = universal;
    self.nonce = NSUUID.UUID.UUIDString;
    uint64_t generation = ++self.generation;
    self.deadline = ClockNanos() + 120ull * NSEC_PER_SEC;
    __weak typeof(self) weakSelf = self;
    self.background = [app beginBackgroundTaskWithName:@"Juice StikDebug handoff" expirationHandler:^{
        JuiceSideStoreCoordinator *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.generation != generation) return;
        strongSelf.cancelled = YES;
        [strongSelf finishHandoff:@"The iOS background time budget expired. Return to Juice and retry JIT authorization."];
    }];
    if (self.background == UIBackgroundTaskInvalid) {
        self.pending = nil;
        Alert(self.owner, @"JIT handoff unavailable", @"iOS did not grant a background handoff budget. Return to the foreground and retry.");
        return;
    }
    self.opening = YES;
    NSURLComponents *url = [NSURLComponents new]; url.scheme = scheme; url.host = @"enable-jit";
    NSMutableArray *items = [NSMutableArray arrayWithArray:@[
        [NSURLQueryItem queryItemWithName:@"bundle-id" value:NSBundle.mainBundle.bundleIdentifier],
        [NSURLQueryItem queryItemWithName:@"pid" value:[NSString stringWithFormat:@"%d", getpid()]]]];
    if (universal) [items addObject:[NSURLQueryItem queryItemWithName:@"script-name" value:@"universal.js"]];
    url.queryItems = items;
    Log(self.owner, [NSString stringWithFormat:@"SIDESTORE_JIT_REQUEST bundle=%@ pid=%d generation=%llu session=%@ protocol=%@\n",
        NSBundle.mainBundle.bundleIdentifier, getpid(), (unsigned long long)generation, self.nonce,
        universal ? @"universal.js" : @"attach-detach"]);
    [self.button setTitle:@"Waiting for StikDebug…" forState:UIControlStateNormal];
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.timer, DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(self.timer, ^{
        JuiceSideStoreCoordinator *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.generation != generation || strongSelf.preparing) return;
        if (ClockNanos() >= strongSelf.deadline) { [strongSelf finishHandoff:@"StikDebug authorization timed out."]; return; }
        if (!strongSelf.accepted || strongSelf.cancelled || !Debugged(universal)) return;
        strongSelf.preparing = YES;
        dispatch_async(strongSelf.queue, ^{
            int error = juice_runtime_prepare_jit(universal);
            dispatch_async(dispatch_get_main_queue(), ^{
                strongSelf.preparing = NO;
                if (strongSelf.generation != generation) return;
                NSString *failure = error ? [NSString stringWithFormat:@"JIT memory preparation failed: %s (%d). No Wine code was started.", strerror(error), error] : nil;
                if (strongSelf.cancelled || ClockNanos() >= strongSelf.deadline)
                    failure = @"JIT preparation returned after cancellation. The guest was not launched.";
                [strongSelf finishHandoff:failure];
            });
        });
    });
    dispatch_resume(self.timer);
    [app openURL:url.URL options:@{} completionHandler:^(BOOL accepted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            JuiceSideStoreCoordinator *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.generation != generation || !strongSelf.opening) return;
            strongSelf.accepted = accepted;
            if (!accepted) [strongSelf finishHandoff:@"iOS could not open the StikDebug JIT request."];
        });
    }];
}
- (void)finishHandoff:(NSString *)failure
{
    if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
    self.opening = NO;
    if (self.background != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:self.background]; self.background = UIBackgroundTaskInvalid;
    }
    if (failure) {
        self.pending = nil;
        Log(self.owner, [@"SIDESTORE_JIT_FAILED " stringByAppendingFormat:@"%@\n", failure]);
        [self.button setTitle:@"Enable JIT with StikDebug" forState:UIControlStateNormal];
        Alert(self.owner, @"JIT was not enabled for launch", failure);
    } else {
        Log(self.owner, [NSString stringWithFormat:@"SIDESTORE_JIT_READY pid=%d session=%@ executable_probe=42\n", getpid(), self.nonce]);
        [self.button setTitle:@"JIT ready — Juice app process" forState:UIControlStateNormal];
        [self tryStart];
    }
}
- (void)launch
{
    if (self.starting || RuntimeActive || juice_runtime_consumed()) {
        Alert(self.owner, @"One runtime session per app launch", @"Stop this session, close Juice from the app switcher, and reopen it before selecting another Windows process. Wine's globals are not safely unloadable in-place.");
        return;
    }
    if (self.pending || self.opening || self.preparing) {
        Alert(self.owner, @"Launch already pending", @"Finish or cancel the current StikDebug handoff first."); return;
    }
    self.cancelled = NO;
    CallVoid(self.owner, @"preparePrefix");
    NSString *profileError = JuiceProfilePreparationError(self.owner);
    NSString *selectedPrefix = Value(self.owner, @"prefix");
    for (NSString *registry in @[@"system.reg", @"user.reg"]) {
        NSString *path = [selectedPrefix stringByAppendingPathComponent:registry];
        NSDictionary *attributes = path ? [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] : nil;
        if (![attributes[NSFileSize] unsignedLongLongValue] || ![NSFileManager.defaultManager isReadableFileAtPath:path])
            profileError = @"The SideStore prefix could not be created. Export the Juice log and check free storage; Wine was not started.";
    }
    NSString *exe = Call(self.owner, @"resolveExe");
    NSString *root = Value(self.owner, @"grape");
    NSDictionary *preflight = JuiceRuntimePreflight(exe, root, [Value(self.owner, @"usingX64") boolValue], [Value(self.owner, @"usingWin32") boolValue]);
    if (profileError || ![preflight[@"can_launch"] boolValue]) {
        Alert(self.owner, @"Cannot start this Windows executable", profileError ?: [preflight[@"failures"] componentsJoinedByString:@"\n"]); return;
    }
    NSString *error = nil;
    NSArray *arguments = JuiceSideStoreParseArguments([Value(self.owner, @"argsField") text] ?: @"", &error);
    NSString *cwd = JuiceProfileWorkingDirectory(self.owner, exe.stringByDeletingLastPathComponent);
    if (!arguments || !cwd) { Alert(self.owner, @"Invalid launch profile", error ?: @"The working directory is unavailable."); return; }
    NSMutableDictionary *environment = [NSMutableDictionary dictionary];
    NSArray *base = Call(self.owner, @"environment");
    for (NSString *entry in base) {
        NSRange equals = [entry rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *key = [entry substringToIndex:equals.location];
        if ([key hasPrefix:@"DYLD_"] || [key hasPrefix:@"JUICE_LOWVA"] || [key hasPrefix:@"JUICE_EXPERIMENTAL"] ||
            [@[@"WINELOADER", @"WINESERVER", @"WINESERVERSOCKET", @"WINELOADERNOEXEC", @"HODLL"] containsObject:key]) continue;
        environment[key] = [entry substringFromIndex:equals.location + 1];
    }
    NSString *prefix = Value(self.owner, @"prefix");
    environment[@"WINEPREFIX"] = prefix;
    environment[@"WINEDLLPATH"] = [root stringByAppendingPathComponent:@"runtime/lib/wine/aarch64-windows"];
    environment[@"JUICE_EMBEDDED"] = @"1";
    environment[@"JUICE_SKIP_WINEBOOT"] = @"1";
    environment[@"JUICE_STIKDEBUG_JIT"] = @"1";
    environment[@"JUICE_STIKDEBUG_JIT_POOL_MB"] = @"256";
    environment[@"JUICE_STIKDEBUG_TXM"] = @"0"; /* embedded allocator owns the prepared arena */
    environment[@"WINEARCH"] = @"win64";
    environment[@"SSL_CERT_FILE"] = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Libraries/ca-certificates.pem"];
    NSString *serverRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:@"jws"];
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:serverRoot withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:&directoryError]) {
        Alert(self.owner, @"Runtime directory unavailable", directoryError.localizedDescription); return;
    }
    environment[@"JUICE_WINESERVER_ROOT"] = serverRoot;
    NSMutableArray *strings = [NSMutableArray array];
    for (NSString *key in [environment.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [strings addObject:[NSString stringWithFormat:@"%@=%@", key, environment[key]]];
    NSMutableArray *argv = [NSMutableArray arrayWithObjects:@"JuiceEmbedded", exe, nil]; [argv addObjectsFromArray:arguments];
    self.pending = @{@"root": root, @"prefix": prefix, @"cwd": cwd, @"environment": strings, @"argv": argv};
    if (juice_runtime_jit_ready()) [self tryStart]; else [self enable];
}
- (void)tryStart
{
    if (!self.pending || self.opening || self.preparing || self.starting || self.cancelled ||
        !juice_runtime_jit_ready() || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSDictionary *request = self.pending; self.pending = nil; self.starting = YES;
    int input[2] = {-1, -1}, output[2] = {-1, -1};
    if (pipe(input) || pipe(output)) {
        int error = errno;
        for (int i = 0; i < 2; ++i) { if (input[i] >= 0) close(input[i]); if (output[i] >= 0) close(output[i]); }
        self.starting = NO; Alert(self.owner, @"Runtime I/O failed", [NSString stringWithUTF8String:strerror(error)]); return;
    }
    for (int i = 0; i < 2; ++i) { fcntl(input[i], F_SETFD, FD_CLOEXEC); fcntl(output[i], F_SETFD, FD_CLOEXEC); }
    fcntl(input[1], F_SETNOSIGPIPE, 1); fcntl(output[1], F_SETNOSIGPIPE, 1);
    Set(self.owner, @"childInput", @(input[1]));
    self.outputReader = [[NSFileHandle alloc] initWithFileDescriptor:output[0] closeOnDealloc:YES];
    NSFileHandle *reader = self.outputReader;
    __weak typeof(self) weakSelf = self;
    NSMutableData *partialUTF8 = [NSMutableData data];
    reader.readabilityHandler = ^(NSFileHandle *handle) {
        @synchronized(handle) { @try {
            uint8_t bytes[16384];
            ssize_t count;
            do { count = read(handle.fileDescriptor, bytes, sizeof(bytes)); } while (count < 0 && errno == EINTR);
            if (count < 0) { if (errno != EAGAIN) handle.readabilityHandler = nil; return; }
            if (count > 0) [partialUTF8 appendBytes:bytes length:(NSUInteger)count];
            size_t complete = count ? JuiceUTF8CompletePrefix(partialUTF8.bytes, partialUTF8.length) : partialUTF8.length;
            uint8_t sanitized[(16384 + 4) * 3]; size_t consumed = 0;
            size_t used = JuiceUTF8Sanitize(partialUTF8.bytes, complete, sanitized, sizeof(sanitized), &consumed);
            NSString *line = [[NSString alloc] initWithBytes:sanitized length:used encoding:NSUTF8StringEncoding];
            if (consumed) [partialUTF8 replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
            if (partialUTF8.length > 4) [partialUTF8 setLength:0]; /* bounded even on malformed input */
            if (line.length) Log(weakSelf.owner, line);
            if (!count) handle.readabilityHandler = nil;
        } @catch (__unused NSException *exception) { handle.readabilityHandler = nil; }}
    };
    NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
    int inputRead = input[0], outputWrite = output[1], inputWrite = input[1];
    /* The coordinator is held by its controller and, after configure, by this
     * explicit process-lifetime reference. Callback context never dangles. */
    static JuiceSideStoreCoordinator *activeCoordinator;
    activeCoordinator = self;
    dispatch_async(self.queue, ^{
        char **environment = CopyStrings(request[@"environment"]), **argv = CopyStrings(request[@"argv"]);
        int error = environment && argv ? 0 : ENOMEM;
        void *client = NULL, *server = NULL;
        if (!error) {
            client = dlopen([frameworks stringByAppendingPathComponent:@"JuiceNTDLL.framework/JuiceNTDLL"].fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
            server = dlopen([frameworks stringByAppendingPathComponent:@"JuiceWineServer.framework/JuiceWineServer"].fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
            if (!client || !server) { Log(self.owner, [NSString stringWithFormat:@"SIDESTORE_DYLD_ERROR %s\n", dlerror() ?: "framework unavailable"]); error = ENOEXEC; }
        }
        unsigned (*clientABI)(void) = client ? dlsym(client, "JuiceEmbeddedWineABI") : NULL;
        unsigned (*serverABI)(void) = server ? dlsym(server, "JuiceEmbeddedWineServerABI") : NULL;
        JuiceWineClientEntry startClient = client ? dlsym(client, "JuiceEmbeddedWineMain") : NULL;
        JuiceWineServerEntry startServer = server ? dlsym(server, "JuiceEmbeddedWineServerMain") : NULL;
        if (!error && (!clientABI || !serverABI || !startClient || !startServer ||
            clientABI() != JUICE_EMBEDDED_ABI || serverABI() != JUICE_EMBEDDED_ABI)) error = EPROTO;
        if (!error) {
            JuiceRuntimeConfiguration config = {.abi=JUICE_EMBEDDED_ABI, .size=sizeof(config),
                .runtime_root=[request[@"root"] fileSystemRepresentation], .frameworks_root=frameworks.fileSystemRepresentation,
                .prefix=[request[@"prefix"] fileSystemRepresentation], .working_directory=[request[@"cwd"] fileSystemRepresentation],
                .environment=environment, .standard_fds={inputRead, outputWrite, outputWrite},
                .notify=RuntimeNotification, .context=(__bridge void *)self};
            error = juice_runtime_configure(&config);
        }
        close(inputRead); close(outputWrite);
        if (!error) error = juice_runtime_start(startServer, startClient, (int)[request[@"argv"] count], argv);
        FreeStrings(environment); FreeStrings(argv);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.starting = NO;
            if (error) {
                if ([Value(self.owner, @"childInput") intValue] == inputWrite) { close(inputWrite); Set(self.owner, @"childInput", @(-1)); }
                Alert(self.owner, @"Embedded runtime could not start", [NSString stringWithFormat:@"%s (%d). See the exported Juice log. No child-process fallback was attempted.", strerror(error), error]);
            } else {
                RuntimeActive = !juice_runtime_stopping();
                Log(self.owner, @"SIDESTORE_RUNTIME_STARTED child_processes=0 guest_processes=1\n");
            }
        });
    });
}
- (void)stop:(NSString *)reason
{
    self.cancelled = YES; self.pending = nil;
    if (!self.preparing && self.opening) [self finishHandoff:@"JIT handoff cancelled."];
    if (self.starting || juice_runtime_consumed()) juice_runtime_request_stop();
    int fd = [Value(self.owner, @"childInput") intValue];
    if (fd >= 0) { close(fd); Set(self.owner, @"childInput", @(-1)); }
    Log(self.owner, [NSString stringWithFormat:@"SIDESTORE_STOP_REQUEST reason=%@ host_pid=%d host_signal=0\n", reason, getpid()]);
}
- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_timer) dispatch_source_cancel(_timer);
}
@end

static JuiceSideStoreCoordinator *Coordinator(id owner)
{
    JuiceSideStoreCoordinator *result = objc_getAssociatedObject(owner, &CoordinatorKey);
    if (!result) {
        result = [JuiceSideStoreCoordinator new]; result.owner = owner;
        objc_setAssociatedObject(owner, &CoordinatorKey, result, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return result;
}
void JuiceSideStoreAttach(id owner)
{
    JuiceSideStoreCoordinator *coordinator = Coordinator(owner);
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem]; coordinator.button = button;
    [button setTitle:@"Enable JIT with StikDebug" forState:UIControlStateNormal];
    [button addTarget:coordinator action:@selector(enable) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *form = Value(owner, @"form");
    if ([form isKindOfClass:UIStackView.class]) [form insertArrangedSubview:button atIndex:0];
    UISwitch *wineboot = Value(owner, @"winebootSwitch"); wineboot.on = YES; wineboot.enabled = NO;
    Log(owner, [NSString stringWithFormat:@"SIDESTORE_HOST bundle=%@ pid=%d get_task_allow=%d backend=embedded abi=%u\n",
        NSBundle.mainBundle.bundleIdentifier, getpid(), Entitled(), juice_runtime_abi()]);
    Log(owner, @"SideStore runtime: one 64-bit Windows process per Juice launch. No Unix helpers, 32-bit guest, Windows subprocesses, or Wineboot service bootstrap. Enable JIT before launching.\n");
}
void JuiceSideStoreLaunch(id owner) { [Coordinator(owner) launch]; }
void JuiceSideStoreStop(id owner, NSString *reason) { [Coordinator(owner) stop:reason]; }
void JuiceSideStoreEnableJIT(id owner) { [Coordinator(owner) enable]; }
BOOL JuiceSideStoreRuntimeActive(void) { return RuntimeActive; }
