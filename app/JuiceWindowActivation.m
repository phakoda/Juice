#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define JUICE_INPUT_LEFT_DOWN 1u
#define JUICE_INPUT_RIGHT_DOWN 4u

typedef struct
{
    uint32_t magic, type, size;
    uint64_t hwnd;
    int32_t x, y, width, height;
    uint32_t stride, flags;
} JuiceActivationMsg;

static void (*JuiceOriginalHandleCanvasInputForActivation)(id, SEL, JuiceActivationMsg);

static id JuiceActivationValue(id self, NSString *key)
{
    @try { return [self valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceActivationHandleInput(id self, SEL _cmd, JuiceActivationMsg message)
{
    if (JuiceOriginalHandleCanvasInputForActivation)
        JuiceOriginalHandleCanvasInputForActivation(self, _cmd, message);

    if (!(message.flags & (JUICE_INPUT_LEFT_DOWN | JUICE_INPUT_RIGHT_DOWN)) ||
        ![JuiceActivationValue(self, @"experimentalMultiWindow") boolValue])
        return;

    uint64_t hwnd = [JuiceActivationValue(self, @"inputHwnd") unsignedLongLongValue];
    NSMutableArray<NSNumber *> *order = JuiceActivationValue(self, @"wineWindowOrder");
    if (!hwnd || ![order isKindOfClass:NSMutableArray.class]) return;

    NSNumber *key = @(hwnd);
    NSUInteger previous = [order indexOfObject:key];
    if (previous == NSNotFound || previous + 1 == order.count) return;

    [order removeObjectAtIndex:previous];
    [order addObject:key];

    SEL composite = NSSelectorFromString(@"compositeWineDesktop");
    if ([self respondsToSelector:composite])
        ((void (*)(id, SEL))objc_msgSend)(self, composite);
}

__attribute__((constructor))
static void JuiceInstallWindowActivation(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(@"handleCanvasInput:"));
    if (!method) return;
    JuiceOriginalHandleCanvasInputForActivation = (void (*)(id, SEL, JuiceActivationMsg))
        method_setImplementation(method, (IMP)JuiceActivationHandleInput);
}
