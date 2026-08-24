#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

/*
 * UIKit images are presentation snapshots; JuiceRuntimeHardening keeps the
 * mutable per-HWND framebuffer separately so dirty rectangles can continue to
 * merge correctly. Under memory pressure, hidden-window UIImage snapshots are
 * therefore safe to discard without throwing away the protocol baseline. The
 * next Wine frame for that HWND recreates the image from the retained backing
 * store.
 */

static void (*JuiceOriginalDidReceiveMemoryWarning)(id, SEL);

static id JuiceMemoryValue(id object, NSString *key)
{
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceMemorySetValue(id object, NSString *key, id value)
{
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static void JuiceMemoryAppend(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static uint64_t JuiceApproximateImageBytes(UIImage *image)
{
    CGImageRef cg = image.CGImage;
    if (!cg) return 0;
    size_t row = CGImageGetBytesPerRow(cg);
    size_t height = CGImageGetHeight(cg);
    if (height && row > UINT64_MAX / height) return UINT64_MAX;
    return (uint64_t)row * height;
}

static void JuiceMemoryDidReceiveWarning(id self, SEL _cmd)
{
    if (JuiceOriginalDidReceiveMemoryWarning)
        JuiceOriginalDidReceiveMemoryWarning(self, _cmd);

    NSMutableDictionary *windows = JuiceMemoryValue(self, @"wineWindows");
    if (![windows isKindOfClass:NSMutableDictionary.class]) return;

    __block NSUInteger trimmed = 0;
    __block uint64_t approximateBytes = 0;
    [windows enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, id state, BOOL *stop) {
        (void)key;
        (void)stop;
        if ([JuiceMemoryValue(state, @"visible") boolValue]) return;
        UIImage *image = JuiceMemoryValue(state, @"image");
        if (![image isKindOfClass:UIImage.class]) return;
        approximateBytes += JuiceApproximateImageBytes(image);
        JuiceMemorySetValue(state, @"image", nil);
        trimmed++;
    }];

    /* In multi-window mode the legacy pointer is not the active compositor
       source. Clearing its extra retain helps an image disappear immediately
       when it belonged to a hidden/obsolete legacy surface. */
    if ([JuiceMemoryValue(self, @"experimentalMultiWindow") boolValue])
        JuiceMemorySetValue(self, @"lastLegacyImage", nil);

    [[NSURLCache sharedURLCache] removeAllCachedResponses];

    if (trimmed)
    {
        SEL composite = NSSelectorFromString(@"compositeWineDesktop");
        if ([self respondsToSelector:composite] &&
            [JuiceMemoryValue(self, @"experimentalMultiWindow") boolValue])
            ((void (*)(id, SEL))objc_msgSend)(self, composite);
    }

    JuiceMemoryAppend(self, [NSString stringWithFormat:
        @"MEMORY_PRESSURE hidden_images_trimmed=%lu approx_bytes=%llu tracked_windows=%lu\n",
        (unsigned long)trimmed, (unsigned long long)approximateBytes,
        (unsigned long)windows.count]);
}

__attribute__((constructor(400)))
static void JuiceInstallMemoryPressureHandling(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;
    SEL selector = @selector(didReceiveMemoryWarning);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    JuiceOriginalDidReceiveMemoryWarning = (void (*)(id, SEL))
        method_setImplementation(method, (IMP)JuiceMemoryDidReceiveWarning);
}
