#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>

/*
 * Direct MSI support for the normal iOS document picker.
 *
 * The runtime already packages Wine's ARM64 msiexec.exe plus msi.dll and the
 * surrounding installer/service/RPC plumbing. The original host importer only
 * treated .exe and .zip as user-facing selections even though the Windows-side
 * control protocol already accepts MSI. Copy an explicitly selected MSI into
 * Juice's writable import area, then launch the bundled msiexec through the
 * normal architecture/spawn path with a quoted Z: path.
 *
 * Grape-X64 intentionally keeps helper programs such as msiexec native ARM64
 * while replacing its DLL layer with ARM64X/hybrid modules. If the user enabled
 * FEX, request that hybrid environment for this one native-helper launch so an
 * installer has the best chance of running x86/x64 custom actions and child
 * processes. Without FEX enabled, the same MSI uses the lighter native runtime.
 */

static void (*JuiceOriginalMSIPicker)(id, SEL, UIDocumentPickerViewController *, NSArray<NSURL *> *);
static void (*JuiceOriginalMSIViewDidLoad)(id, SEL);

static id JuiceMSIValue(id object, NSString *key)
{
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceMSIAppend(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static NSString *JuiceMSIDocuments(void)
{
    NSString *legacy = @"/var/mobile/Documents";
    if (access(legacy.fileSystemRepresentation, W_OK) == 0) return legacy;
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                      NSUserDomainMask, YES);
    NSString *documents = paths.firstObject;
    return documents.length ? documents : [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
}

static NSString *JuiceMSIImportDestination(NSString *name, NSError **error)
{
    NSString *imports = [[JuiceMSIDocuments() stringByAppendingPathComponent:@"JuiceData"]
                         stringByAppendingPathComponent:@"Imported"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:imports
                                  withIntermediateDirectories:YES attributes:nil error:error])
        return nil;

    NSString *destination = [imports stringByAppendingPathComponent:name];
    if (![NSFileManager.defaultManager fileExistsAtPath:destination]) return destination;
    NSString *stem = name.stringByDeletingPathExtension.length ? name.stringByDeletingPathExtension : @"installer";
    NSString *unique = [NSString stringWithFormat:@"%@-%@.msi", stem, NSUUID.UUID.UUIDString];
    return [imports stringByAppendingPathComponent:unique];
}

static NSString *JuiceWindowsPathForUnixPath(NSString *path)
{
    return [@"Z:" stringByAppendingString:
            [path stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
}

static void JuiceMSIPicked(id self, SEL _cmd, UIDocumentPickerViewController *controller,
                           NSArray<NSURL *> *urls)
{
    NSURL *url = urls.firstObject;
    BOOL controlPicker = controller == JuiceMSIValue(self, @"controlPicker");
    if (!url || controlPicker || ![url.pathExtension.lowercaseString isEqualToString:@"msi"])
    {
        if (JuiceOriginalMSIPicker) JuiceOriginalMSIPicker(self, _cmd, controller, urls);
        return;
    }

    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString *name = url.lastPathComponent.length ? url.lastPathComponent : @"installer.msi";
    NSError *error = nil;
    NSString *destination = JuiceMSIImportDestination(name, &error);
    if (destination)
        [NSFileManager.defaultManager copyItemAtURL:url
                                              toURL:[NSURL fileURLWithPath:destination]
                                              error:&error];
    if (scoped) [url stopAccessingSecurityScopedResource];

    if (error || !destination.length)
    {
        JuiceMSIAppend(self, [NSString stringWithFormat:
            @"MSI_IMPORT_FAILED file=%@ error=%@\n", name,
            error.localizedDescription ?: @"could not prepare the import directory"]);
        return;
    }

    NSString *windowsPath = JuiceWindowsPathForUnixPath(destination);
    UITextField *exe = JuiceMSIValue(self, @"exeField");
    UITextField *args = JuiceMSIValue(self, @"argsField");
    UISegmentedControl *mode = JuiceMSIValue(self, @"mode");
    if (![exe isKindOfClass:UITextField.class] || ![args isKindOfClass:UITextField.class])
    {
        JuiceMSIAppend(self, @"MSI_IMPORT_FAILED reason=launcher-unavailable\n");
        return;
    }

    exe.text = @"msiexec.exe";
    args.text = [NSString stringWithFormat:@"/i \"%@\"", windowsPath];
    if ([mode isKindOfClass:UISegmentedControl.class]) mode.selectedSegmentIndex = 0;

    BOOL hybrid = [JuiceMSIValue(self, @"experimentalX64") boolValue];
    if (hybrid)
    {
        SEL force = NSSelectorFromString(@"juice_forceTranslatedRuntimeForNextLaunch");
        if ([self respondsToSelector:force])
            ((void (*)(id, SEL))objc_msgSend)(self, force);
    }

    JuiceMSIAppend(self, [NSString stringWithFormat:
        @"MSI_IMPORT_READY local=%@ windows=%@ launcher=msiexec.exe hybrid_runtime=%d\n",
        destination, windowsPath, hybrid]);

    SEL launch = NSSelectorFromString(@"launchRequested");
    if ([self respondsToSelector:launch])
        ((void (*)(id, SEL))objc_msgSend)(self, launch);
}

static void JuiceRenameMSIPickerButton(UIView *view)
{
    if ([view isKindOfClass:UIButton.class])
    {
        UIButton *button = (UIButton *)view;
        NSString *title = [button titleForState:UIControlStateNormal];
        if ([title isEqualToString:@"Choose EXE or Portable ZIP"])
            [button setTitle:@"Choose EXE, MSI or Portable ZIP" forState:UIControlStateNormal];
    }
    for (UIView *subview in view.subviews) JuiceRenameMSIPickerButton(subview);
}

static void JuiceMSIViewDidLoad(id self, SEL _cmd)
{
    if (JuiceOriginalMSIViewDidLoad) JuiceOriginalMSIViewDidLoad(self, _cmd);
    if ([self isKindOfClass:UIViewController.class])
        JuiceRenameMSIPickerButton(((UIViewController *)self).view);
}

__attribute__((constructor(360)))
static void JuiceInstallMSIImport(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;

    Method picker = class_getInstanceMethod(cls, NSSelectorFromString(@"documentPicker:didPickDocumentsAtURLs:"));
    if (picker)
        JuiceOriginalMSIPicker = (void (*)(id, SEL, UIDocumentPickerViewController *, NSArray<NSURL *> *))
            method_setImplementation(picker, (IMP)JuiceMSIPicked);

    Method view = class_getInstanceMethod(cls, NSSelectorFromString(@"viewDidLoad"));
    if (view)
        JuiceOriginalMSIViewDidLoad = (void (*)(id, SEL))
            method_setImplementation(view, (IMP)JuiceMSIViewDidLoad);
}
