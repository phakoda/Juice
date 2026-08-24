#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "../wine/dlls/wineios.drv/control_protocol.h"

/*
 * The original control bridge predates automatic PE routing and rejects every
 * JUICE_CONTROL_ACTION_LAUNCH_PATH unless the x86-64 experimental switch is
 * already enabled. That incorrectly blocks native ARM64 Windows programs and
 * duplicates architecture policy in two places.
 *
 * Resolve the Windows path, populate the normal launcher fields, and delegate
 * to launchRequested. JuiceArchitectureRouting then makes the single decision:
 * ARM64 uses Grape; i386/x86-64/ARM64EC require the translated Grape-X64 path.
 */

static void (*JuiceOriginalControlAction)(id, SEL, uint32_t, NSString *);

static id JuiceControlValue(id object, NSString *key)
{
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceControlAppend(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static NSString *JuiceControlUnixPath(id self, NSString *windowsPath)
{
    SEL selector = NSSelectorFromString(@"unixPathForWindowsPath:");
    if (![self respondsToSelector:selector]) return windowsPath ?: @"";
    id value = ((id (*)(id, SEL, id))objc_msgSend)(self, selector, windowsPath ?: @"");
    return [value isKindOfClass:NSString.class] ? value : (windowsPath ?: @"");
}

static void JuiceRoutedControlAction(id self, SEL _cmd, uint32_t action, NSString *windowsPath)
{
    if (action != JUICE_CONTROL_ACTION_LAUNCH_PATH)
    {
        if (JuiceOriginalControlAction)
            JuiceOriginalControlAction(self, _cmd, action, windowsPath);
        return;
    }

    NSString *path = JuiceControlUnixPath(self, windowsPath);
    if (!path.length)
    {
        JuiceControlAppend(self, @"CONTROL_V1_LAUNCH_REJECTED reason=empty-path\n");
        return;
    }

    UITextField *exe = JuiceControlValue(self, @"exeField");
    UITextField *args = JuiceControlValue(self, @"argsField");
    UISegmentedControl *mode = JuiceControlValue(self, @"mode");
    if (![exe isKindOfClass:UITextField.class])
    {
        JuiceControlAppend(self, @"CONTROL_V1_LAUNCH_REJECTED reason=launcher-unavailable\n");
        return;
    }

    exe.text = path;
    if ([args isKindOfClass:UITextField.class]) args.text = @"";
    if ([mode isKindOfClass:UISegmentedControl.class]) mode.selectedSegmentIndex = 0;

    JuiceControlAppend(self, [NSString stringWithFormat:
        @"CONTROL_V1_LAUNCH_ROUTE windows=%@ unix=%@ architecture=auto\n",
        windowsPath ?: @"", path]);

    SEL launch = NSSelectorFromString(@"launchRequested");
    if ([self respondsToSelector:launch])
        ((void (*)(id, SEL))objc_msgSend)(self, launch);
}

__attribute__((constructor(310)))
static void JuiceInstallControlLaunchRouting(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;
    SEL selector = NSSelectorFromString(@"handleControlAction:path:");
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    JuiceOriginalControlAction = (void (*)(id, SEL, uint32_t, NSString *))
        method_setImplementation(method, (IMP)JuiceRoutedControlAction);
}
