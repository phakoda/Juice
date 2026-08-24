#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>

/* User-facing launchers for Windows data files that Wine already knows how to
 * consume but which are not PE executables themselves. */

static void (*JuiceOriginalScriptPicker)(id, SEL, UIDocumentPickerViewController *, NSArray<NSURL *> *);
static void (*JuiceOriginalScriptViewDidLoad)(id, SEL);

static id JuiceScriptValue(id object, NSString *key)
{
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceScriptAppend(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static NSString *JuiceScriptDocuments(void)
{
    NSString *legacy = @"/var/mobile/Documents";
    if (access(legacy.fileSystemRepresentation, W_OK) == 0) return legacy;
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                      NSUserDomainMask, YES);
    return paths.firstObject.length ? paths.firstObject
                                    : [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
}

static NSString *JuiceScriptCopyImport(NSURL *url, NSError **error)
{
    NSString *imports = [[JuiceScriptDocuments() stringByAppendingPathComponent:@"JuiceData"]
                         stringByAppendingPathComponent:@"Imported"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:imports
                                  withIntermediateDirectories:YES attributes:nil error:error])
        return nil;

    NSString *name = url.lastPathComponent.length ? url.lastPathComponent : @"windows-file";
    NSString *destination = [imports stringByAppendingPathComponent:name];
    if ([NSFileManager.defaultManager fileExistsAtPath:destination])
    {
        NSString *extension = name.pathExtension;
        NSString *stem = name.stringByDeletingPathExtension.length ? name.stringByDeletingPathExtension : @"windows-file";
        NSString *unique = extension.length
            ? [NSString stringWithFormat:@"%@-%@.%@", stem, NSUUID.UUID.UUIDString, extension]
            : [NSString stringWithFormat:@"%@-%@", stem, NSUUID.UUID.UUIDString];
        destination = [imports stringByAppendingPathComponent:unique];
    }
    [NSFileManager.defaultManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:destination] error:error];
    return *error ? nil : destination;
}

static NSString *JuiceScriptWindowsPath(NSString *path)
{
    return [@"Z:" stringByAppendingString:
            [path stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
}

static void JuiceScriptPicked(id self, SEL _cmd, UIDocumentPickerViewController *controller,
                              NSArray<NSURL *> *urls)
{
    NSURL *url = urls.firstObject;
    BOOL control = controller == JuiceScriptValue(self, @"controlPicker");
    NSString *extension = url.pathExtension.lowercaseString;
    BOOL batch = [extension isEqualToString:@"bat"] || [extension isEqualToString:@"cmd"];
    BOOL registry = [extension isEqualToString:@"reg"];
    if (!url || control || (!batch && !registry))
    {
        if (JuiceOriginalScriptPicker) JuiceOriginalScriptPicker(self, _cmd, controller, urls);
        return;
    }

    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *error = nil;
    NSString *destination = JuiceScriptCopyImport(url, &error);
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!destination.length || error)
    {
        JuiceScriptAppend(self, [NSString stringWithFormat:
            @"WINDOWS_DATA_IMPORT_FAILED file=%@ error=%@\n",
            url.lastPathComponent ?: @"", error.localizedDescription ?: @"copy failed"]);
        return;
    }

    NSString *windowsPath = JuiceScriptWindowsPath(destination);
    UITextField *exe = JuiceScriptValue(self, @"exeField");
    UITextField *args = JuiceScriptValue(self, @"argsField");
    UISegmentedControl *mode = JuiceScriptValue(self, @"mode");
    if (![exe isKindOfClass:UITextField.class] || ![args isKindOfClass:UITextField.class]) return;

    BOOL hybrid = batch && [JuiceScriptValue(self, @"experimentalX64") boolValue];
    if (batch)
    {
        exe.text = @"cmd.exe";
        args.text = [NSString stringWithFormat:@"/c \"%@\"", windowsPath];
    }
    else
    {
        exe.text = @"reg.exe";
        args.text = [NSString stringWithFormat:@"import \"%@\"", windowsPath];
    }
    if ([mode isKindOfClass:UISegmentedControl.class]) mode.selectedSegmentIndex = 0;

    if (hybrid)
    {
        SEL force = NSSelectorFromString(@"juice_forceTranslatedRuntimeForNextLaunch");
        if ([self respondsToSelector:force]) ((void (*)(id, SEL))objc_msgSend)(self, force);
    }

    JuiceScriptAppend(self, [NSString stringWithFormat:
        @"WINDOWS_DATA_IMPORT_READY kind=%@ local=%@ windows=%@ hybrid_runtime=%d\n",
        batch ? @"batch" : @"registry", destination, windowsPath, hybrid]);
    SEL launch = NSSelectorFromString(@"launchRequested");
    if ([self respondsToSelector:launch]) ((void (*)(id, SEL))objc_msgSend)(self, launch);
}

static void JuiceRenameScriptPickerButton(UIView *view)
{
    if ([view isKindOfClass:UIButton.class])
    {
        UIButton *button = (UIButton *)view;
        NSString *title = [button titleForState:UIControlStateNormal];
        if ([title isEqualToString:@"Choose EXE, MSI or Portable ZIP"])
            [button setTitle:@"Choose Windows App, Installer or ZIP" forState:UIControlStateNormal];
    }
    for (UIView *subview in view.subviews) JuiceRenameScriptPickerButton(subview);
}

static void JuiceScriptViewDidLoad(id self, SEL _cmd)
{
    if (JuiceOriginalScriptViewDidLoad) JuiceOriginalScriptViewDidLoad(self, _cmd);
    if ([self isKindOfClass:UIViewController.class])
        JuiceRenameScriptPickerButton(((UIViewController *)self).view);
}

__attribute__((constructor(365)))
static void JuiceInstallScriptImport(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;
    Method picker = class_getInstanceMethod(cls, NSSelectorFromString(@"documentPicker:didPickDocumentsAtURLs:"));
    if (picker)
        JuiceOriginalScriptPicker = (void (*)(id, SEL, UIDocumentPickerViewController *, NSArray<NSURL *> *))
            method_setImplementation(picker, (IMP)JuiceScriptPicked);
    Method view = class_getInstanceMethod(cls, NSSelectorFromString(@"viewDidLoad"));
    if (view)
        JuiceOriginalScriptViewDidLoad = (void (*)(id, SEL))
            method_setImplementation(view, (IMP)JuiceScriptViewDidLoad);
}
