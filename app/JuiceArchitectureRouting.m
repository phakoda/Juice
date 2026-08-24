#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <signal.h>
#import <sys/wait.h>

#define JUICE_PE_I386 0x014cu
#define JUICE_PE_AMD64 0x8664u
#define JUICE_PE_ARM64 0xaa64u
#define JUICE_PE_ARM64EC 0xa641u

static NSArray *(*JuiceOriginalEnvironment)(id, SEL);
static char JuiceSelectedMachineKey;

static id JuiceArchValue(id self, NSString *key)
{
    @try { return [self valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceArchSetValue(id self, NSString *key, id value)
{
    @try { [self setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static void JuiceArchAppend(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static NSString *JuiceCandidateExecutable(id self)
{
    SEL selector = NSSelectorFromString(@"candidateExePath");
    return [self respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(self, selector) : nil;
}

static uint16_t JuiceExecutableMachine(id self, NSString *path)
{
    SEL selector = NSSelectorFromString(@"machineForExecutableAtPath:");
    if (![self respondsToSelector:selector]) return 0;
    return ((uint16_t (*)(id, SEL, id))objc_msgSend)(self, selector, path);
}

static NSString *JuiceMachineName(id self, uint16_t machine)
{
    SEL selector = NSSelectorFromString(@"nameForMachine:");
    if (![self respondsToSelector:selector]) return @"unknown";
    return ((id (*)(id, SEL, uint16_t))objc_msgSend)(self, selector, machine) ?: @"unknown";
}

static void JuiceRejectArchitecture(id self, NSString *message)
{
    SEL selector = NSSelectorFromString(@"rejectLaunch:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, message);
    else
        JuiceArchAppend(self, [NSString stringWithFormat:@"ARCH_ROUTE_REJECTED %@\n", message]);
}

static BOOL JuiceWin32RuntimeReady(NSString *runtime, NSString **missing)
{
    NSArray<NSString *> *required = @[
        @"runtime/lib/wine/i386-windows/ntdll.dll",
        @"runtime/lib/wine/aarch64-windows/libwow64fex.dll"
    ];
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSString *relative in required)
    {
        NSString *path = [runtime stringByAppendingPathComponent:relative];
        if (![files fileExistsAtPath:path])
        {
            if (missing) *missing = relative;
            return NO;
        }
    }
    return YES;
}

static void JuiceArchitectureLaunchRequested(id self, SEL _cmd)
{
    (void)_cmd;
    NSString *path = JuiceCandidateExecutable(self);
    uint16_t machine = JuiceExecutableMachine(self, path);
    if (!machine)
    {
        JuiceRejectArchitecture(self, [NSString stringWithFormat:
            @"Juice could not read a valid PE architecture from %@.", path.lastPathComponent ?: @"the selected file"]);
        return;
    }

    BOOL win32 = machine == JUICE_PE_I386;
    BOOL x64 = machine == JUICE_PE_AMD64 || machine == JUICE_PE_ARM64EC;
    BOOL translated = win32 || x64;
    if (machine != JUICE_PE_ARM64 && !translated)
    {
        JuiceRejectArchitecture(self, [NSString stringWithFormat:@"Unsupported PE machine 0x%04x.", machine]);
        return;
    }

    BOOL experimentalEnabled = [JuiceArchValue(self, @"experimentalX64") boolValue];
    if (translated && !experimentalEnabled)
    {
        JuiceRejectArchitecture(self, win32
            ? @"This is a 32-bit x86 app. Open Experimental and enable x86-64 / FEX translation; the packaged Grape-X64 runtime also carries the Win32 WoW64 translator."
            : @"This is an x86_64/ARM64EC app. Open Experimental and enable x86-64 / FEX translation.");
        return;
    }

    NSString *runtimeName = translated ? @"Grape-X64" : @"Grape";
    NSString *runtime = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:runtimeName];
    NSString *loader = [runtime stringByAppendingPathComponent:@"build/wine-ios/loader/wine"];
    if (![NSFileManager.defaultManager isExecutableFileAtPath:loader])
    {
        JuiceRejectArchitecture(self, [NSString stringWithFormat:@"%@ is not installed in this build.", runtimeName]);
        return;
    }

    if (win32)
    {
        NSString *missing = nil;
        if (!JuiceWin32RuntimeReady(runtime, &missing))
        {
            JuiceRejectArchitecture(self, [NSString stringWithFormat:
                @"This build does not contain the experimental Win32 WoW64/FEX runtime (%@ is missing). Rebuild Juice with JUICE_REQUIRE_WIN32=1.", missing]);
            return;
        }
    }

    pid_t server = [JuiceArchValue(self, @"server") intValue];
    BOOL serverUsingTranslatedRuntime = [JuiceArchValue(self, @"serverUsingX64") boolValue];
    if (server > 0 && serverUsingTranslatedRuntime != translated)
    {
        kill(server, SIGTERM);
        waitpid(server, NULL, WNOHANG);
        JuiceArchSetValue(self, @"server", @(-1));
    }

    JuiceArchSetValue(self, @"usingX64", @(translated));
    objc_setAssociatedObject(self, &JuiceSelectedMachineKey, @(machine), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    JuiceArchAppend(self, [NSString stringWithFormat:
        @"PE_ARCH_DETECTED machine=0x%04x arch=%@ runtime=%@ path=%@ win32_wow64=%d\n",
        machine, JuiceMachineName(self, machine), runtimeName, path, win32]);

    SEL launch = NSSelectorFromString(@"launchTapped");
    if ([self respondsToSelector:launch])
        ((void (*)(id, SEL))objc_msgSend)(self, launch);
    JuiceArchSetValue(self, @"serverUsingX64", @(translated));
}

static NSArray *JuiceArchitectureEnvironment(id self, SEL _cmd)
{
    NSArray *base = JuiceOriginalEnvironment ? JuiceOriginalEnvironment(self, _cmd) : @[];
    uint16_t machine = [objc_getAssociatedObject(self, &JuiceSelectedMachineKey) unsignedShortValue];
    if (machine != JUICE_PE_I386) return base;

    NSMutableArray *environment = [base mutableCopy] ?: [NSMutableArray array];
    BOOL found = NO;
    for (NSUInteger index = 0; index < environment.count; index++)
    {
        NSString *entry = environment[index];
        if ([entry hasPrefix:@"HODLL="])
        {
            environment[index] = @"HODLL=libwow64fex.dll";
            found = YES;
            break;
        }
    }
    if (!found) [environment addObject:@"HODLL=libwow64fex.dll"];
    [environment addObject:@"JUICE_EXPERIMENTAL_WIN32=1"];
    return environment;
}

__attribute__((constructor))
static void JuiceInstallArchitectureRouting(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;

    Method launch = class_getInstanceMethod(cls, NSSelectorFromString(@"launchRequested"));
    if (launch) method_setImplementation(launch, (IMP)JuiceArchitectureLaunchRequested);

    Method environment = class_getInstanceMethod(cls, NSSelectorFromString(@"environment"));
    if (environment)
        JuiceOriginalEnvironment = (NSArray *(*)(id, SEL))
            method_setImplementation(environment, (IMP)JuiceArchitectureEnvironment);
}
