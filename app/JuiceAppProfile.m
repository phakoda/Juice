#import "JuiceAppProfile.h"
#import "JuiceProfilePolicy.h"
#import "JuiceRuntimePreflight.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const ProfilesKey = @"JuiceAppProfiles.v1";
static char PreparationErrorKey;
static void (*OriginalRebuildProfileMenu)(id, SEL);
static NSArray<NSString *> *(*OriginalProfileEnvironment)(id, SEL);
static void (*OriginalProfilePreparePrefix)(id, SEL);

static id Value(id owner, NSString *key)
{
    @try { return [owner valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}
static void SetValue(id owner, NSString *key, id value)
{
    @try { [owner setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}
static void Append(id owner, NSString *text)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([owner respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(owner, selector, text);
}
static NSString *String(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSString *ProfilePath(id owner)
{
    UITextField *field = Value(owner, @"exeField");
    NSString *path = [field isKindOfClass:UITextField.class] ? field.text : nil;
    if (!path.isAbsolutePath) {
        SEL selector = NSSelectorFromString(@"candidateExePath");
        if ([owner respondsToSelector:selector]) path = String(((id (*)(id, SEL))objc_msgSend)(owner, selector));
    }
    if (!path.isAbsolutePath || path.length > 8192) return nil;
    for (NSUInteger i = 0; i < path.length; i++) if (![path characterAtIndex:i]) return nil;
    return path.stringByStandardizingPath;
}
static NSDictionary *AllProfiles(void)
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:ProfilesKey];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
static NSDictionary *Profile(id owner)
{
    NSString *path = ProfilePath(owner);
    id value = path ? AllProfiles()[path] : nil;
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"schema"] isEqual:@1]) return @{};
    return value;
}
static void Alert(id owner, NSString *message)
{
    if (![owner isKindOfClass:UIViewController.class]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Launch profile"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [(UIViewController *)owner presentViewController:alert animated:YES completion:nil];
}
static BOOL SafeText(NSString *s, NSUInteger maximum)
{
    NSData *encoded = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (!encoded || encoded.length > maximum) return NO;
    for (NSUInteger i = 0; i < s.length; i++) if (![s characterAtIndex:i]) return NO;
    return YES;
}
static BOOL ValidWorkingDirectory(NSString *path)
{
    BOOL directory = NO;
    return path.isAbsolutePath && SafeText(path, 8192) &&
        [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] && directory &&
        [NSFileManager.defaultManager isReadableFileAtPath:path];
}
static BOOL SaveProfile(id owner, NSDictionary *value)
{
    NSString *path = ProfilePath(owner);
    if (!path) { Alert(owner, @"Select an executable with an absolute path first."); return NO; }
    NSMutableDictionary *all = [AllProfiles() mutableCopy];
    if (!all[path] && all.count >= 128) {
        Alert(owner, @"The 128-profile limit has been reached. Remove an unused profile first."); return NO;
    }
    NSMutableDictionary *profile = [value mutableCopy];
    profile[@"schema"] = @1;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:String(profile[@"id"])];
    profile[@"id"] = uuid ? uuid.UUIDString : NSUUID.UUID.UUIDString;
    all[path] = profile;
    [NSUserDefaults.standardUserDefaults setObject:all forKey:ProfilesKey];
    return YES;
}
BOOL JuiceProfileJITRequested(id owner)
{
    return [Profile(owner)[@"jit"] isEqual:@YES];
}
NSString *JuiceProfilePrefixName(id owner, NSString *baseName)
{
    NSDictionary *profile = Profile(owner);
    if (![profile[@"isolated"] isEqual:@YES]) return baseName;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:String(profile[@"id"])];
    return uuid ? [baseName stringByAppendingFormat:@"-%@", uuid.UUIDString] : baseName;
}
NSString *JuiceProfileWorkingDirectory(id owner, NSString *fallback)
{
    NSString *cwd = String(Profile(owner)[@"cwd"]);
    if (!cwd.length) return fallback;
    return ValidWorkingDirectory(cwd) ? cwd.stringByStandardizingPath : nil;
}
NSString *JuiceProfilePreparationError(id owner)
{
    id value = objc_getAssociatedObject(owner, &PreparationErrorKey);
    return [value isKindOfClass:NSString.class] ? value : nil;
}
NSArray<NSString *> *JuiceProfileEnvironment(id owner, NSArray<NSString *> *base)
{
    NSDictionary *profile = Profile(owner);
    NSString *overrides = String(profile[@"dll_overrides"]);
    NSData *wire = [overrides dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary<NSString *, NSString *> *changes = [NSMutableDictionary dictionary];
    if ([profile[@"quiet"] isEqual:@YES]) changes[@"WINEDEBUG"] = @"-all";
    if (overrides.length && wire && JuiceDLLOverridesValid(wire.bytes, wire.length))
        changes[@"WINEDLLOVERRIDES"] = overrides;
    if ([profile[@"jit"] isEqual:@YES]) changes[@"JUICE_ENABLE_STIKDEBUG_JIT"] = @"1";
    if (!changes.count) return base;
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSString *entry in base) {
        NSRange equals = [entry rangeOfString:@"="];
        NSString *key = equals.location == NSNotFound ? entry : [entry substringToIndex:equals.location];
        if (!changes[key]) [result addObject:entry];
    }
    for (NSString *key in [changes.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [result addObject:[NSString stringWithFormat:@"%@=%@", key, changes[key]]];
    return result;
}
static BOOL FileNonempty(NSString *path)
{
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    return [attributes[NSFileSize] unsignedLongLongValue] != 0;
}
static BOOL ReadyMarkerValid(NSString *prefix)
{
    NSString *ready = [prefix stringByAppendingPathComponent:@".juice-prefix-ready"];
    NSString *contents = [NSString stringWithContentsOfFile:ready encoding:NSUTF8StringEncoding error:nil];
    return [[contents stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
            isEqualToString:@"JUICE_PREFIX_READY"] &&
           FileNonempty([prefix stringByAppendingPathComponent:@"system.reg"]) &&
           FileNonempty([prefix stringByAppendingPathComponent:@"user.reg"]);
}
static void EnsureLink(NSString *path, NSString *target)
{
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *existing = [files destinationOfSymbolicLinkAtPath:path error:nil];
    if ([existing isEqualToString:target]) return;
    if (existing || [files fileExistsAtPath:path]) [files removeItemAtPath:path error:nil];
    [files createSymbolicLinkAtPath:path withDestinationPath:target error:nil];
}
static void RefreshRuntimeLinks(id owner, NSString *prefix)
{
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *grape = String(Value(owner, @"grape"));
    if (!grape.length || !prefix.length) return;
    NSString *dos = [prefix stringByAppendingPathComponent:@"dosdevices"];
    [files createDirectoryAtPath:dos withIntermediateDirectories:YES attributes:nil error:nil];
    EnsureLink([dos stringByAppendingPathComponent:@"c:"], @"../drive_c");
    EnsureLink([dos stringByAppendingPathComponent:@"z:"], @"/");

    NSArray<NSArray<NSString *> *> *sets = @[
        @[[grape stringByAppendingPathComponent:@"runtime/lib/wine/aarch64-windows"],
          [prefix stringByAppendingPathComponent:@"drive_c/windows/system32"]],
        @[[grape stringByAppendingPathComponent:@"runtime/lib/wine/i386-windows"],
          [prefix stringByAppendingPathComponent:@"drive_c/windows/syswow64"]]
    ];
    BOOL usingWin32 = [Value(owner, @"usingWin32") boolValue];
    for (NSUInteger setIndex = 0; setIndex < sets.count; ++setIndex) {
        if (setIndex == 1 && !usingWin32) break;
        NSString *sourceRoot = sets[setIndex][0], *destinationRoot = sets[setIndex][1];
        [files createDirectoryAtPath:destinationRoot withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *name in [files contentsOfDirectoryAtPath:sourceRoot error:nil] ?: @[]) {
            NSString *ext = name.pathExtension.lowercaseString;
            if (!([ext isEqualToString:@"dll"] || [ext isEqualToString:@"exe"] || [ext isEqualToString:@"drv"])) continue;
            NSString *source = [sourceRoot stringByAppendingPathComponent:name];
            NSString *destination = [destinationRoot stringByAppendingPathComponent:name];
            NSString *existing = [files destinationOfSymbolicLinkAtPath:destination error:nil];
            if (existing && ![existing isEqualToString:source]) [files removeItemAtPath:destination error:nil];
            if (![files fileExistsAtPath:destination])
                [files createSymbolicLinkAtPath:destination withDestinationPath:source error:nil];
        }
    }
}
static void ProfilePreparePrefix(id owner, SEL selector)
{
    objc_setAssociatedObject(owner, &PreparationErrorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    OriginalProfilePreparePrefix(owner, selector);
    NSDictionary *profile = Profile(owner);
    if (![profile[@"isolated"] isEqual:@YES]) return;

    NSString *basePrefix = String(Value(owner, @"prefix"));
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:String(profile[@"id"])];
    if (!basePrefix.length || !uuid) {
        objc_setAssociatedObject(owner, &PreparationErrorKey, @"The isolated profile is missing a valid prefix identity.", OBJC_ASSOCIATION_COPY_NONATOMIC);
        return;
    }
    NSString *target = [basePrefix stringByAppendingFormat:@"-%@", uuid.UUIDString];
    NSFileManager *files = NSFileManager.defaultManager;
    BOOL directory = NO;
    if (![files fileExistsAtPath:target isDirectory:&directory]) {
        NSError *copyError = nil;
        if (![files copyItemAtPath:basePrefix toPath:target error:&copyError]) {
            NSString *message = [NSString stringWithFormat:@"Could not create the isolated Wine prefix: %@", copyError.localizedDescription ?: @"unknown error"];
            objc_setAssociatedObject(owner, &PreparationErrorKey, message, OBJC_ASSOCIATION_COPY_NONATOMIC);
            Append(owner, [NSString stringWithFormat:@"PROFILE_PREFIX_CREATE_FAILED path=%@ error=%@\n", target, copyError.localizedDescription ?: @"unknown"]);
            return;
        }
        directory = YES;
        Append(owner, [NSString stringWithFormat:@"PROFILE_PREFIX_CREATED base=%@ isolated=%@\n", basePrefix, target]);
    }
    if (!directory) {
        objc_setAssociatedObject(owner, &PreparationErrorKey, @"The isolated prefix path exists but is not a directory.", OBJC_ASSOCIATION_COPY_NONATOMIC);
        return;
    }
    if (!ReadyMarkerValid(target))
        [files removeItemAtPath:[target stringByAppendingPathComponent:@".juice-prefix-ready"] error:nil];
    SetValue(owner, @"prefix", target);
    SetValue(owner, @"prefixNeedsInitialization", @(!ReadyMarkerValid(target)));
    RefreshRuntimeLinks(owner, target);
    Append(owner, [NSString stringWithFormat:@"PROFILE_PREFIX_SELECTED path=%@ needs_init=%d\n",
                   target, [Value(owner, @"prefixNeedsInitialization") boolValue]]);
}
static NSArray<NSString *> *ProfileEnvironment(id owner, SEL selector)
{
    NSArray<NSString *> *base = OriginalProfileEnvironment(owner, selector);
    return JuiceProfileEnvironment(owner, base ?: @[]);
}
static void Rebuild(id owner)
{
    SEL selector = NSSelectorFromString(@"rebuildExperimentalMenu");
    if ([owner respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(owner, selector);
}
static BOOL StikDebugAvailable(void)
{
    UIApplication *app = UIApplication.sharedApplication;
    return [app canOpenURL:[NSURL URLWithString:@"stikdebug://"]] || [app canOpenURL:[NSURL URLWithString:@"stikjit://"]];
}
static void EditProfile(id owner)
{
    if (![owner isKindOfClass:UIViewController.class] || !ProfilePath(owner)) { Alert(owner, @"Select an executable first."); return; }
    NSString *editedPath = ProfilePath(owner);
    NSDictionary *profile = Profile(owner);
    UIAlertController *editor = [UIAlertController alertControllerWithTitle:@"Current app launch profile"
        message:@"Applies on the next launch. DLL overrides do not install DLLs. An empty working directory uses the executable's folder."
        preferredStyle:UIAlertControllerStyleAlert];
    UITextField *args = Value(owner, @"argsField");
    [editor addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Arguments";
        field.text = [args isKindOfClass:UITextField.class] ? args.text : String(profile[@"arguments"]);
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [editor addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Working directory (absolute path)"; field.text = String(profile[@"cwd"]);
        field.autocorrectionType = UITextAutocorrectionTypeNo; field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [editor addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"DLL overrides, e.g. d3d11,dxgi=n,b"; field.text = String(profile[@"dll_overrides"]);
        field.autocorrectionType = UITextAutocorrectionTypeNo; field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak id weakOwner = owner;
    __weak UIAlertController *weakEditor = editor;
    [editor addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        id target = weakOwner; UIAlertController *form = weakEditor;
        if (!target || !form) return;
        if (![ProfilePath(target) isEqualToString:editedPath]) { Alert(target, @"The selected application changed. Reopen its launch profile before saving."); return; }
        NSString *arguments = form.textFields[0].text ?: @"";
        NSString *cwd = form.textFields[1].text ?: @"";
        NSString *overrides = form.textFields[2].text ?: @"";
        NSData *wire = [overrides dataUsingEncoding:NSUTF8StringEncoding];
        NSString *error = !SafeText(arguments, 65536) ? @"Arguments must be valid UTF-8, at most 64 KiB, and contain no NUL." :
            cwd.length && !ValidWorkingDirectory(cwd) ? @"The working directory must be an existing, readable absolute directory." :
            !wire || !JuiceDLLOverridesValid(wire.bytes, wire.length) ? @"Use module=n,b DLL override syntax, at most 4 KiB. Empty load orders disable a module." : nil;
        if (error) { Alert(target, error); return; }
        NSMutableDictionary *updated = [Profile(target) mutableCopy];
        updated[@"arguments"] = arguments; updated[@"cwd"] = cwd; updated[@"dll_overrides"] = overrides;
        if (SaveProfile(target, updated)) {
            UITextField *field = Value(target, @"argsField");
            if ([field isKindOfClass:UITextField.class]) field.text = arguments;
            Rebuild(target);
        }
    }]];
    [editor addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [(UIViewController *)owner presentViewController:editor animated:YES completion:nil];
}
static void LogPreflight(id owner)
{
    SEL prepare = NSSelectorFromString(@"preparePrefix");
    SEL resolve = NSSelectorFromString(@"resolveExe");
    if (![owner respondsToSelector:prepare] || ![owner respondsToSelector:resolve]) return;
    ((void (*)(id, SEL))objc_msgSend)(owner, prepare);
    NSString *exe = ((id (*)(id, SEL))objc_msgSend)(owner, resolve);
    NSString *runtime = String(Value(owner, @"grape"));
    NSDictionary *result = JuiceRuntimePreflight(exe, runtime, [Value(owner, @"usingX64") boolValue], [Value(owner, @"usingWin32") boolValue]);
    Append(owner, [NSString stringWithFormat:@"COMPATIBILITY_PREFLIGHT machine=%@ arch=%@ managed=%@ can_launch=%@ failures=%@ warnings=%@\n",
                   result[@"machine"], result[@"architecture"], result[@"managed"], result[@"can_launch"], result[@"failures"], result[@"warnings"]]);
}
static void ProfileMenu(id owner, SEL selector)
{
    OriginalRebuildProfileMenu(owner, selector);
    UIButton *button = Value(owner, @"experimentalButton");
    if (![button isKindOfClass:UIButton.class] || !button.menu) return;
    __weak id weakOwner = owner;
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    [items addObject:[UIAction actionWithTitle:@"Edit current app launch profile…" image:nil identifier:nil handler:^(__unused UIAction *action) {
        id target = weakOwner; if (target) EditProfile(target);
    }]];
    NSDictionary *profile = Profile(owner);
    #ifdef JUICE_SIDESTORE
    NSArray *profileKeys = @[@"isolated", @"quiet"];
#else
    NSArray *profileKeys = @[@"isolated", @"quiet", @"jit"];
#endif
    for (NSString *key in profileKeys) {
        NSString *title = [key isEqualToString:@"isolated"] ? @"Isolated prefix (next launch)" :
                          [key isEqualToString:@"quiet"] ? @"Reduce Wine debug logging" :
                          @"StikDebug JIT for translated apps";
        UIAction *toggle = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(__unused UIAction *action) {
            id target = weakOwner; if (!target) return;
            if ([key isEqualToString:@"jit"] && ![Profile(target)[key] isEqual:@YES] && !StikDebugAvailable()) {
                Alert(target, @"StikDebug/StikJIT is not installed or cannot be opened. Install/configure it before enabling this per-app JIT backend.");
                return;
            }
            NSMutableDictionary *updated = [Profile(target) mutableCopy];
            updated[key] = @(![updated[key] isEqual:@YES]);
            if (SaveProfile(target, updated)) Rebuild(target);
        }];
        toggle.state = [profile[key] isEqual:@YES] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:toggle];
    }
    [items addObject:[UIAction actionWithTitle:@"Use saved arguments" image:nil identifier:nil handler:^(__unused UIAction *action) {
        id target = weakOwner; if (!target) return;
        UITextField *field = Value(target, @"argsField");
        NSString *saved = String(Profile(target)[@"arguments"]);
        if ([field isKindOfClass:UITextField.class] && SafeText(saved, 65536)) field.text = saved;
    }]];
    [items addObject:[UIAction actionWithTitle:@"Log compatibility preflight" image:nil identifier:nil handler:^(__unused UIAction *action) {
        id target = weakOwner; if (target) LogPreflight(target);
    }]];
    [items addObject:[UIAction actionWithTitle:@"Remove launch profile (keep prefix files)" image:nil identifier:nil handler:^(__unused UIAction *action) {
        id target = weakOwner; NSString *path = target ? ProfilePath(target) : nil;
        if (!path) return;
        NSMutableDictionary *all = [AllProfiles() mutableCopy]; [all removeObjectForKey:path];
        [NSUserDefaults.standardUserDefaults setObject:all forKey:ProfilesKey]; Rebuild(target);
    }]];
    NSMutableArray<UIMenuElement *> *children = [button.menu.children mutableCopy] ?: [NSMutableArray array];
    [children addObject:[UIMenu menuWithTitle:@"Per-app compatibility" children:items]];
    button.menu = [UIMenu menuWithTitle:button.menu.title children:children];
}
__attribute__((constructor(700)))
static void InstallProfileHooks(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;
    Method menu = class_getInstanceMethod(cls, NSSelectorFromString(@"rebuildExperimentalMenu"));
    if (menu) OriginalRebuildProfileMenu = (void (*)(id, SEL))method_setImplementation(menu, (IMP)ProfileMenu);
    Method environment = class_getInstanceMethod(cls, NSSelectorFromString(@"environment"));
    if (environment) OriginalProfileEnvironment = (void *)method_setImplementation(environment, (IMP)ProfileEnvironment);
    Method prepare = class_getInstanceMethod(cls, NSSelectorFromString(@"preparePrefix"));
    if (prepare) OriginalProfilePreparePrefix = (void *)method_setImplementation(prepare, (IMP)ProfilePreparePrefix);
}
