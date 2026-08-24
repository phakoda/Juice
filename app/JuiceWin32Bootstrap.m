#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void (*JuiceOriginalPreparePrefixForWin32)(id, SEL);

static id JuiceWin32Value(id self, NSString *key)
{
    @try { return [self valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceWin32Append(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static BOOL JuiceEnsureRuntimeLink(NSFileManager *files, NSString *source,
                                   NSString *destination, NSError **error)
{
    NSString *target = [files destinationOfSymbolicLinkAtPath:destination error:nil];
    if ([target isEqualToString:source]) return YES;

    if (target)
    {
        if (![files removeItemAtPath:destination error:error]) return NO;
    }
    else if ([files fileExistsAtPath:destination])
    {
        /* Do not overwrite a real Windows-created file. Prefix upgrades should
           be conservative; Wine can still locate the runtime copy through
           WINEDLLPATH. */
        return YES;
    }

    return [files createSymbolicLinkAtPath:destination withDestinationPath:source error:error];
}

static void JuiceRepairWin32Prefix(id self)
{
    if (![JuiceWin32Value(self, @"usingX64") boolValue]) return;

    NSString *grape = JuiceWin32Value(self, @"grape");
    NSString *prefix = JuiceWin32Value(self, @"prefix");
    if (!grape.length || !prefix.length) return;

    NSFileManager *files = NSFileManager.defaultManager;
    NSString *runtime32 = [grape stringByAppendingPathComponent:@"runtime/lib/wine/i386-windows"];
    BOOL isDirectory = NO;
    if (![files fileExistsAtPath:runtime32 isDirectory:&isDirectory] || !isDirectory)
        return; /* x64-only experimental build; nothing to repair */

    NSString *syswow64 = [prefix stringByAppendingPathComponent:@"drive_c/windows/syswow64"];
    NSError *error = nil;
    if (![files createDirectoryAtPath:syswow64 withIntermediateDirectories:YES attributes:nil error:&error])
    {
        JuiceWin32Append(self, [NSString stringWithFormat:
            @"PREFIX_WIN32_ERROR stage=syswow64 error=%@\n", error.localizedDescription ?: @"unknown"]);
        return;
    }

    NSUInteger linked = 0;
    NSUInteger preserved = 0;
    for (NSString *name in [files contentsOfDirectoryAtPath:runtime32 error:&error] ?: @[])
    {
        NSString *extension = name.pathExtension.lowercaseString;
        if (!([extension isEqualToString:@"dll"] || [extension isEqualToString:@"exe"] ||
              [extension isEqualToString:@"drv"] || [extension isEqualToString:@"sys"]))
            continue;

        NSString *source = [runtime32 stringByAppendingPathComponent:name];
        NSString *destination = [syswow64 stringByAppendingPathComponent:name];
        BOOL existed = [files fileExistsAtPath:destination] ||
                       [files destinationOfSymbolicLinkAtPath:destination error:nil] != nil;
        NSError *linkError = nil;
        if (JuiceEnsureRuntimeLink(files, source, destination, &linkError))
        {
            if (existed) preserved++;
            else linked++;
        }
        else
        {
            JuiceWin32Append(self, [NSString stringWithFormat:
                @"PREFIX_WIN32_LINK_ERROR module=%@ error=%@\n",
                name, linkError.localizedDescription ?: @"unknown"]);
        }
    }

    NSString *translator = [grape stringByAppendingPathComponent:
                            @"runtime/lib/wine/aarch64-windows/libwow64fex.dll"];
    NSString *system32 = [prefix stringByAppendingPathComponent:@"drive_c/windows/system32"];
    NSString *translatorDestination = [system32 stringByAppendingPathComponent:@"libwow64fex.dll"];
    if ([files fileExistsAtPath:translator])
    {
        [files createDirectoryAtPath:system32 withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *translatorError = nil;
        if (!JuiceEnsureRuntimeLink(files, translator, translatorDestination, &translatorError))
            JuiceWin32Append(self, [NSString stringWithFormat:
                @"PREFIX_WIN32_TRANSLATOR_ERROR error=%@\n",
                translatorError.localizedDescription ?: @"unknown"]);
    }

    JuiceWin32Append(self, [NSString stringWithFormat:
        @"PREFIX_WIN32_READY syswow64=%@ linked=%lu existing=%lu translator=%d\n",
        syswow64, (unsigned long)linked, (unsigned long)preserved,
        [files fileExistsAtPath:translator]]);
}

static void JuicePreparePrefixWithWin32(id self, SEL _cmd)
{
    if (JuiceOriginalPreparePrefixForWin32)
        JuiceOriginalPreparePrefixForWin32(self, _cmd);
    JuiceRepairWin32Prefix(self);
}

__attribute__((constructor))
static void JuiceInstallWin32Bootstrap(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(@"preparePrefix"));
    if (!method) return;
    JuiceOriginalPreparePrefixForWin32 = (void (*)(id, SEL))
        method_setImplementation(method, (IMP)JuicePreparePrefixWithWin32);
}
