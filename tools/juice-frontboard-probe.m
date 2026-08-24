#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static void print_methods(Class cls, const char *scope)
{
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int index = 0; index < count; index++)
    {
        SEL selector = method_getName(methods[index]);
        const char *name = sel_getName(selector);
        if (strstr(name, "openApplication") || strstr(name, "activateApplication"))
            printf("%s selector=%s types=%s\n", scope, name,
                   method_getTypeEncoding(methods[index]));
    }
    free(methods);
}

int main(int argc, const char **argv)
{
    @autoreleasepool
    {
        const char *framework =
            "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices";
        void *handle = dlopen(framework, RTLD_NOW | RTLD_LOCAL);
        if (!handle)
        {
            fprintf(stderr, "FRONTBOARD_PROBE_DLOPEN_FAILED error=%s\n", dlerror());
            return 2;
        }

        Class cls = NSClassFromString(@"FBSSystemService");
        if (!cls)
        {
            fprintf(stderr, "FRONTBOARD_PROBE_CLASS_MISSING\n");
            return 3;
        }
        print_methods(object_getClass(cls), "class");
        print_methods(cls, "instance");
        printf("FRONTBOARD_PROBE_METHOD_LIST_OK\n");

        if (argc < 2) return 0;
        NSString *bundleID = [NSString stringWithUTF8String:argv[1]];
        if (argc >= 3 && !strcmp(argv[2], "--springboard-only"))
        {
            const char *springBoardFramework =
                "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices";
            void *springBoardHandle = dlopen(springBoardFramework, RTLD_NOW | RTLD_LOCAL);
            int (*launchApplication)(CFStringRef, Boolean) = springBoardHandle ?
                (int (*)(CFStringRef, Boolean))dlsym(
                    springBoardHandle, "SBSLaunchApplicationWithIdentifier") : NULL;
            if (!launchApplication)
            {
                fprintf(stderr, "SPRINGBOARD_PROBE_SYMBOL_MISSING\n");
                return 8;
            }
            int launchResult = launchApplication((__bridge CFStringRef)bundleID, false);
            printf("SPRINGBOARD_PROBE_FOREGROUND_RESULT bundle=%s result=%d\n",
                   argv[1], launchResult);
            return launchResult ? 9 : 0;
        }
        SEL sharedSelector = NSSelectorFromString(@"sharedService");
        SEL openSelector = NSSelectorFromString(@"openApplication:options:withResult:");
        if (![cls respondsToSelector:sharedSelector])
        {
            fprintf(stderr, "FRONTBOARD_PROBE_SHARED_SERVICE_MISSING\n");
            return 4;
        }
        id service = ((id (*)(id, SEL))objc_msgSend)(cls, sharedSelector);
        if (![service respondsToSelector:openSelector])
        {
            fprintf(stderr, "FRONTBOARD_PROBE_OPEN_METHOD_MISSING\n");
            return 5;
        }

        CFStringRef *unlockKeyAddress = (CFStringRef *)dlsym(
            handle, "FBSOpenApplicationOptionKeyUnlockDevice");
        NSMutableDictionary *options = [NSMutableDictionary dictionary];
        if (unlockKeyAddress && *unlockKeyAddress)
            options[(__bridge NSString *)*unlockKeyAddress] = @YES;
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        __block NSError *resultError = nil;
        void (^completion)(NSError *) = ^(NSError *error) {
            resultError = error;
            dispatch_semaphore_signal(finished);
        };
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(service, openSelector,
                                                       bundleID, options, completion);
        long waitResult = dispatch_semaphore_wait(finished,
            dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        if (waitResult)
        {
            fprintf(stderr, "FRONTBOARD_PROBE_RESULT_TIMEOUT bundle=%s\n", argv[1]);
            return 6;
        }
        if (resultError)
        {
            fprintf(stderr,
                    "FRONTBOARD_PROBE_OPEN_FAILED bundle=%s domain=%s code=%ld description=%s userInfo=%s\n",
                    argv[1], resultError.domain.UTF8String, (long)resultError.code,
                    resultError.localizedDescription.UTF8String,
                    resultError.userInfo.description.UTF8String);
            return 7;
        }
        printf("FRONTBOARD_PROBE_OPEN_OK bundle=%s\n", argv[1]);

        const char *springBoardFramework =
            "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices";
        void *springBoardHandle = dlopen(springBoardFramework, RTLD_NOW | RTLD_LOCAL);
        if (springBoardHandle)
        {
            int (*launchApplication)(CFStringRef, Boolean) =
                (int (*)(CFStringRef, Boolean))dlsym(
                    springBoardHandle, "SBSLaunchApplicationWithIdentifier");
            if (launchApplication)
            {
                int launchResult = launchApplication((__bridge CFStringRef)bundleID, false);
                printf("SPRINGBOARD_PROBE_FOREGROUND_RESULT bundle=%s result=%d\n",
                       argv[1], launchResult);
            }
        }
    }
    return 0;
}
