#import <UIKit/UIKit.h>
#import <errno.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import "JuiceZip.h"
#import "../wine/dlls/wineios.drv/control_protocol.h"

/*
 * Writable-path compatibility for both jailbreak-style installs and ordinary
 * iOS application containers.
 *
 * Older Juice code assumes /var/mobile/Documents is writable. That is true in
 * common jailbreak deployments but false for a normally sandboxed app, where
 * Documents lives under /var/mobile/Containers/Data/Application/<UUID>/. Keep
 * the legacy location when it is genuinely writable, otherwise use the app's
 * Documents directory. Unix sockets live under tmp to keep sockaddr_un paths
 * short even when the application-container UUID makes Documents fairly long.
 */

static void (*JuiceStorageOriginalViewDidLoad)(id, SEL);
static NSArray *(*JuiceStorageOriginalEnvironment)(id, SEL);

static id JuiceStorageValue(id object, NSString *key)
{
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceStorageSetValue(id object, NSString *key, id value)
{
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static void JuiceStorageAppend(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static NSString *JuiceDocumentsDirectory(void)
{
    static NSString *documents;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *legacy = @"/var/mobile/Documents";
        if (access(legacy.fileSystemRepresentation, W_OK) == 0)
        {
            documents = legacy;
            return;
        }

        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                          NSUserDomainMask, YES);
        documents = paths.firstObject;
        if (!documents.length) documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    });
    return documents;
}

static NSString *JuiceDataDirectory(void)
{
    return [JuiceDocumentsDirectory() stringByAppendingPathComponent:@"JuiceData"];
}

static NSString *JuiceSocketDirectory(void)
{
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"JuiceSockets"];
}

static BOOL JuiceEnsureDirectory(NSString *path, NSError **error)
{
    return [NSFileManager.defaultManager createDirectoryAtPath:path
                                    withIntermediateDirectories:YES
                                                     attributes:nil error:error];
}

static NSString *JuiceUniqueImportPath(NSString *name)
{
    NSString *imports = [JuiceDataDirectory() stringByAppendingPathComponent:@"Imported"];
    JuiceEnsureDirectory(imports, nil);
    NSString *destination = [imports stringByAppendingPathComponent:name];
    if (![NSFileManager.defaultManager fileExistsAtPath:destination]) return destination;

    NSString *stem = name.stringByDeletingPathExtension.length ? name.stringByDeletingPathExtension : @"import";
    NSString *extension = name.pathExtension;
    NSString *unique = extension.length
        ? [NSString stringWithFormat:@"%@-%@.%@", stem, NSUUID.UUID.UUIDString, extension]
        : [NSString stringWithFormat:@"%@-%@", stem, NSUUID.UUID.UUIDString];
    return [imports stringByAppendingPathComponent:unique];
}

static BOOL JuiceBindUnixListener(NSString *path, int backlog, int *resultFD, int *bindError)
{
    if (resultFD) *resultFD = -1;
    if (bindError) *bindError = 0;
    if (!path.length || strlen(path.fileSystemRepresentation) >= sizeof(((struct sockaddr_un *)0)->sun_path))
    {
        if (bindError) *bindError = ENAMETOOLONG;
        return NO;
    }

    unlink(path.fileSystemRepresentation);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
    {
        if (bindError) *bindError = errno;
        return NO;
    }

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, path.fileSystemRepresentation, sizeof(address.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, backlog) != 0)
    {
        int saved = errno;
        close(fd);
        unlink(path.fileSystemRepresentation);
        if (bindError) *bindError = saved;
        return NO;
    }

    if (resultFD) *resultFD = fd;
    return YES;
}

static void JuiceStorageStartDisplayServer(id self, SEL _cmd)
{
    (void)_cmd;
    NSError *directoryError = nil;
    NSString *directory = JuiceSocketDirectory();
    JuiceEnsureDirectory(directory, &directoryError);
    NSString *path = [directory stringByAppendingPathComponent:@"display.sock"];
    JuiceStorageSetValue(self, @"socketPath", path);

    int listenFD = -1, saved = directoryError ? EACCES : 0;
    BOOL ready = !directoryError && JuiceBindUnixListener(path, 8, &listenFD, &saved);
    JuiceStorageSetValue(self, @"listenFD", @(listenFD));
    JuiceStorageAppend(self, [NSString stringWithFormat:
        @"DISPLAY_SOCKET path=%@ ready=%d fd=%d errno=%d sandbox_safe=1\n",
        path, ready, listenFD, saved]);
    if (!ready) return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (;;)
        {
            int fd = accept(listenFD, NULL, NULL);
            if (fd < 0)
            {
                if (errno == EINTR) continue;
                break;
            }
            NSMutableArray *clients = JuiceStorageValue(self, @"clients");
            if ([clients isKindOfClass:NSMutableArray.class])
                @synchronized(clients) { [clients addObject:@(fd)]; }
            JuiceStorageAppend(self, [NSString stringWithFormat:@"DISPLAY_CLIENT_CONNECTED fd=%d\n", fd]);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                SEL selector = NSSelectorFromString(@"readClient:");
                if ([self respondsToSelector:selector])
                    ((void (*)(id, SEL, int))objc_msgSend)(self, selector, fd);
                else close(fd);
            });
        }
    });
}

static void JuiceStorageStartControlServer(id self, SEL _cmd)
{
    (void)_cmd;
    NSError *directoryError = nil;
    NSString *directory = JuiceSocketDirectory();
    JuiceEnsureDirectory(directory, &directoryError);
    NSString *path = [directory stringByAppendingPathComponent:@"control.sock"];
    JuiceStorageSetValue(self, @"controlSocketPath", path);

    int listenFD = -1, saved = directoryError ? EACCES : 0;
    BOOL ready = !directoryError && JuiceBindUnixListener(path, 4, &listenFD, &saved);
    JuiceStorageSetValue(self, @"controlListenFD", @(listenFD));
    JuiceStorageAppend(self, [NSString stringWithFormat:
        @"CONTROL_V1_SOCKET path=%@ ready=%d fd=%d errno=%d sandbox_safe=1\n",
        path, ready, listenFD, saved]);
    if (!ready) return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (;;)
        {
            int fd = accept(listenFD, NULL, NULL);
            if (fd < 0)
            {
                if (errno == EINTR) continue;
                break;
            }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                SEL selector = NSSelectorFromString(@"readControlClient:");
                if ([self respondsToSelector:selector])
                    ((void (*)(id, SEL, int))objc_msgSend)(self, selector, fd);
                else close(fd);
            });
        }
    });
}

static void JuiceStoragePreparePrefix(id self, SEL _cmd)
{
    (void)_cmd;
    BOOL usingX64 = [JuiceStorageValue(self, @"usingX64") boolValue];
    NSString *runtimeName = usingX64 ? @"Grape-X64" : @"Grape";
    NSString *prefixName = usingX64 ? @"GrapePrefix-x86_64" : @"GrapePrefix";
    NSString *grape = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:runtimeName];
    NSString *base = JuiceDataDirectory();
    NSString *prefix = [base stringByAppendingPathComponent:prefixName];
    JuiceStorageSetValue(self, @"grape", grape);
    JuiceStorageSetValue(self, @"prefix", prefix);

    NSFileManager *files = NSFileManager.defaultManager;
    NSError *directoryError = nil;
    if (!JuiceEnsureDirectory(base, &directoryError))
    {
        JuiceStorageAppend(self, [NSString stringWithFormat:
            @"PREFIX_STORAGE_ERROR base=%@ error=%@\n", base,
            directoryError.localizedDescription ?: @"unknown"]);
        return;
    }

    NSString *ready = [prefix stringByAppendingPathComponent:@".juice-prefix-ready"];
    BOOL needsInitialization = ![files fileExistsAtPath:ready];
    JuiceStorageSetValue(self, @"prefixNeedsInitialization", @(needsInitialization));
    if (![files fileExistsAtPath:[prefix stringByAppendingPathComponent:@"system.reg"]])
        [files copyItemAtPath:[grape stringByAppendingPathComponent:@"prefix-template"]
                       toPath:prefix error:nil];

    NSString *dos = [prefix stringByAppendingPathComponent:@"dosdevices"];
    [files createDirectoryAtPath:dos withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *z = [dos stringByAppendingPathComponent:@"z:"];
    [files removeItemAtPath:z error:nil];
    [files createSymbolicLinkAtPath:z withDestinationPath:@"/" error:nil];

    NSString *pe = [grape stringByAppendingPathComponent:@"runtime/lib/wine/aarch64-windows"];
    NSString *system32 = [prefix stringByAppendingPathComponent:@"drive_c/windows/system32"];
    [files createDirectoryAtPath:system32 withIntermediateDirectories:YES attributes:nil error:nil];
    NSUInteger linkedModules = 0;
    for (NSString *name in [files contentsOfDirectoryAtPath:pe error:nil] ?: @[])
    {
        NSString *extension = name.pathExtension.lowercaseString;
        if (!([extension isEqualToString:@"dll"] || [extension isEqualToString:@"exe"] ||
              [extension isEqualToString:@"drv"])) continue;
        NSString *source = [pe stringByAppendingPathComponent:name];
        NSString *destination = [system32 stringByAppendingPathComponent:name];
        BOOL juiceManaged = [name caseInsensitiveCompare:@"JuiceGUI.exe"] == NSOrderedSame ||
                            [name caseInsensitiveCompare:@"JuiceTextSmoke.exe"] == NSOrderedSame ||
                            [name caseInsensitiveCompare:@"winemine.exe"] == NSOrderedSame ||
                            [name caseInsensitiveCompare:@"x86_64-smoke.exe"] == NSOrderedSame;
        if ([files destinationOfSymbolicLinkAtPath:destination error:nil])
            [files removeItemAtPath:destination error:nil];
        if (needsInitialization) continue;
        if (juiceManaged && [files fileExistsAtPath:destination])
            [files removeItemAtPath:destination error:nil];
        if (![files fileExistsAtPath:destination] &&
            [files createSymbolicLinkAtPath:destination withDestinationPath:source error:nil])
            linkedModules++;
    }

    NSString *user = [prefix stringByAppendingPathComponent:@"user.reg"];
    NSMutableString *registry = [NSMutableString stringWithContentsOfFile:user
                                                                  encoding:NSUTF8StringEncoding error:nil];
    if (registry && [registry rangeOfString:@"\"Graphics\"=\"ios\""].location == NSNotFound)
    {
        [registry appendString:@"\n[Software\\\\Wine\\\\Drivers] 1770000000\n#time=1dc790000000000\n\"Graphics\"=\"ios\"\n"];
        [registry writeToFile:user atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    JuiceStorageAppend(self, [NSString stringWithFormat:
        @"RUNTIME_SELECTED runtime=%@ prefix=%@ storage_root=%@\n", runtimeName, prefix, base]);
    JuiceStorageAppend(self, [NSString stringWithFormat:
        @"PREFIX_RUNTIME_LINKS count=%lu system32=%@\n", (unsigned long)linkedModules, system32]);
}

static NSArray *JuiceStorageEnvironment(id self, SEL _cmd)
{
    NSArray *base = JuiceStorageOriginalEnvironment ? JuiceStorageOriginalEnvironment(self, _cmd) : @[];
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:base.count];
    NSString *legacyNative = @"/var/mobile/Documents/JuiceData/native";
    NSString *native = [JuiceDataDirectory() stringByAppendingPathComponent:@"native"];
    for (NSString *entry in base)
    {
        if ([entry hasPrefix:@"WINEDLLPATH="])
            [result addObject:[entry stringByReplacingOccurrencesOfString:legacyNative withString:native]];
        else
            [result addObject:entry];
    }
    return result;
}

static NSArray *JuiceExecutablesBelow(id self, NSString *root)
{
    SEL selector = NSSelectorFromString(@"executablesBelow:");
    return [self respondsToSelector:selector]
        ? ((id (*)(id, SEL, id))objc_msgSend)(self, selector, root) : @[];
}

static void JuiceOfferExecutables(id self, NSArray *paths, NSString *root, NSString *source)
{
    SEL selector = NSSelectorFromString(@"offerExecutables:root:source:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(self, selector, paths, root, source);
}

static void JuiceRunImportedExe(id self, NSString *path, NSString *source)
{
    SEL selector = NSSelectorFromString(@"runImportedExe:source:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id, id))objc_msgSend)(self, selector, path, source);
}

static void JuiceFinishControlImport(id self, int32_t status, NSString *path, NSString *detail)
{
    SEL selector = NSSelectorFromString(@"finishControlImport:path:detail:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, int32_t, id, id))objc_msgSend)(self, selector, status, path, detail);
}

static void JuiceStorageImportPortableZip(id self, SEL _cmd, NSString *source)
{
    (void)_cmd;
    NSString *imports = [JuiceDataDirectory() stringByAppendingPathComponent:@"Imported"];
    JuiceEnsureDirectory(imports, nil);
    NSString *folder = [NSString stringWithFormat:@"%@-%@",
                        source.lastPathComponent.stringByDeletingPathExtension,
                        NSUUID.UUID.UUIDString];
    NSString *destination = [imports stringByAppendingPathComponent:folder];
    JuiceStorageAppend(self, [NSString stringWithFormat:
        @"CONTROL_V1_ZIP_IMPORT_BEGIN source=%@ destination=%@\n", source, destination]);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL extracted = [JuiceZip extractArchiveAtPath:source toDirectory:destination error:&error];
        NSArray *executables = extracted ? JuiceExecutablesBelow(self, destination) : @[];
        if (!extracted) [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!extracted)
            {
                JuiceStorageAppend(self, [NSString stringWithFormat:
                    @"CONTROL_V1_ZIP_IMPORT_FAILED error=%@\n", error.localizedDescription ?: @"unknown"]);
                return;
            }
            JuiceStorageAppend(self, [NSString stringWithFormat:
                @"CONTROL_V1_ZIP_READY root=%@ exe_count=%lu\n",
                destination, (unsigned long)executables.count]);
            if (executables.count) JuiceOfferExecutables(self, executables, destination, source);
        });
    });
}

static void JuiceStorageDidPickDocuments(id self, SEL _cmd, UIDocumentPickerViewController *controller,
                                         NSArray<NSURL *> *urls)
{
    (void)_cmd;
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL control = controller == JuiceStorageValue(self, @"controlPicker");
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString *name = url.lastPathComponent.length ? url.lastPathComponent : @"program.exe";
    NSString *extension = name.pathExtension.lowercaseString;

    if (control)
    {
        if (!([extension isEqualToString:@"msi"] || [extension isEqualToString:@"exe"] ||
              [extension isEqualToString:@"zip"]))
        {
            if (scoped) [url stopAccessingSecurityScopedResource];
            JuiceFinishControlImport(self, JUICE_CONTROL_STATUS_ERROR, @"",
                                     @"Juice accepts .msi, .exe, and .zip files for installation.");
            return;
        }

        NSString *destination = JuiceUniqueImportPath(name);
        NSError *error = nil;
        [NSFileManager.defaultManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:destination] error:&error];
        if (scoped) [url stopAccessingSecurityScopedResource];
        if (error)
        {
            JuiceStorageAppend(self, [NSString stringWithFormat:
                @"CONTROL_V1_IMPORT_FAILED file=%@ error=%@\n", name, error.localizedDescription]);
            JuiceFinishControlImport(self, JUICE_CONTROL_STATUS_ERROR, @"",
                                     error.localizedDescription ?: @"The selected file could not be copied.");
            return;
        }
        NSString *windows = [@"Z:" stringByAppendingString:
            [destination stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
        JuiceStorageAppend(self, [NSString stringWithFormat:
            @"CONTROL_V1_IMPORT_COMPLETE local=%@ windows=%@\n", destination, windows]);
        JuiceFinishControlImport(self, JUICE_CONTROL_STATUS_COMPLETE, windows, @"Imported.");
        return;
    }

    if ([extension isEqualToString:@"exe"])
    {
        NSString *destination = JuiceUniqueImportPath(name);
        NSError *error = nil;
        [NSFileManager.defaultManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:destination] error:&error];
        if (scoped) [url stopAccessingSecurityScopedResource];
        if (error)
        {
            JuiceStorageAppend(self, [NSString stringWithFormat:
                @"CUSTOM_EXE_IMPORT_FAILED file=%@ error=%@\n", name, error.localizedDescription]);
            return;
        }
        JuiceRunImportedExe(self, destination, url.path);
        return;
    }

    if ([extension isEqualToString:@"zip"])
    {
        NSString *imports = [JuiceDataDirectory() stringByAppendingPathComponent:@"Imported"];
        JuiceEnsureDirectory(imports, nil);
        NSString *folder = [NSString stringWithFormat:@"%@-%@", name.stringByDeletingPathExtension,
                            NSUUID.UUID.UUIDString];
        NSString *destination = [imports stringByAppendingPathComponent:folder];
        NSString *source = url.path;
        JuiceStorageAppend(self, [NSString stringWithFormat:
            @"PORTABLE_ZIP_IMPORT_BEGIN source=%@ destination=%@\n", source, destination]);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            BOOL extracted = [JuiceZip extractArchiveAtPath:url.path toDirectory:destination error:&error];
            if (scoped) [url stopAccessingSecurityScopedResource];
            NSArray *executables = extracted ? JuiceExecutablesBelow(self, destination) : @[];
            if (!extracted) [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!extracted)
                {
                    JuiceStorageAppend(self, [NSString stringWithFormat:
                        @"PORTABLE_ZIP_IMPORT_FAILED source=%@ error=%@\n",
                        source, error.localizedDescription ?: @"unknown"]);
                    return;
                }
                JuiceStorageAppend(self, [NSString stringWithFormat:
                    @"PORTABLE_ZIP_READY root=%@ exe_count=%lu\n",
                    destination, (unsigned long)executables.count]);
                if (executables.count) JuiceOfferExecutables(self, executables, destination, source);
            });
        });
        return;
    }

    if (scoped) [url stopAccessingSecurityScopedResource];
    JuiceStorageAppend(self, [NSString stringWithFormat:
        @"CUSTOM_EXE_REJECTED file=%@ reason=not-exe-or-zip\n", name]);
}

static void JuiceStorageViewDidLoad(id self, SEL _cmd)
{
    if (JuiceStorageOriginalViewDidLoad) JuiceStorageOriginalViewDidLoad(self, _cmd);

    NSError *error = nil;
    NSString *data = JuiceDataDirectory();
    JuiceEnsureDirectory(data, &error);
    NSString *log = [data stringByAppendingPathComponent:@"Juice-GUI.log"];
    JuiceStorageSetValue(self, @"persistentLogPath", log);
    if (![NSFileManager.defaultManager fileExistsAtPath:log])
        [@"JUICE_LOG_BEGIN\n" writeToFile:log atomically:YES encoding:NSUTF8StringEncoding error:nil];
    JuiceStorageAppend(self, [NSString stringWithFormat:
        @"HOST_STORAGE documents=%@ data=%@ sockets=%@ writable=%d error=%@\n",
        JuiceDocumentsDirectory(), data, JuiceSocketDirectory(),
        access(data.fileSystemRepresentation, W_OK) == 0,
        error.localizedDescription ?: @"none"]);
}

/* Install before the default-priority feature wrappers so prefix repair,
 * architecture routing and runtime hardening all operate on these paths. */
__attribute__((constructor(150)))
static void JuiceInstallStoragePaths(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;

    Method view = class_getInstanceMethod(cls, NSSelectorFromString(@"viewDidLoad"));
    if (view)
        JuiceStorageOriginalViewDidLoad = (void (*)(id, SEL))
            method_setImplementation(view, (IMP)JuiceStorageViewDidLoad);

    Method display = class_getInstanceMethod(cls, NSSelectorFromString(@"startDisplayServer"));
    if (display) method_setImplementation(display, (IMP)JuiceStorageStartDisplayServer);

    Method control = class_getInstanceMethod(cls, NSSelectorFromString(@"startControlServer"));
    if (control) method_setImplementation(control, (IMP)JuiceStorageStartControlServer);

    Method prefix = class_getInstanceMethod(cls, NSSelectorFromString(@"preparePrefix"));
    if (prefix) method_setImplementation(prefix, (IMP)JuiceStoragePreparePrefix);

    Method environment = class_getInstanceMethod(cls, NSSelectorFromString(@"environment"));
    if (environment)
        JuiceStorageOriginalEnvironment = (NSArray *(*)(id, SEL))
            method_setImplementation(environment, (IMP)JuiceStorageEnvironment);

    Method zip = class_getInstanceMethod(cls, NSSelectorFromString(@"importPortableZipFromLocalPath:"));
    if (zip) method_setImplementation(zip, (IMP)JuiceStorageImportPortableZip);

    Method picker = class_getInstanceMethod(cls, NSSelectorFromString(@"documentPicker:didPickDocumentsAtURLs:"));
    if (picker) method_setImplementation(picker, (IMP)JuiceStorageDidPickDocuments);
}
