#import "JuiceRuntimePreflight.h"
#import "JuicePEInspect.h"
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <unistd.h>

NSDictionary<NSString *, id> *JuiceRuntimePreflight(NSString *exe, NSString *runtime, BOOL x64, BOOL win32)
{
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    NSMutableArray<NSString *> *warnings = [NSMutableArray array];
    JuicePEInfo pe = {0};
    int fd = exe.length ? open(exe.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NONBLOCK) : -1;
    if (fd < 0) [failures addObject:@"The selected executable cannot be opened."];
    else {
        if (JuicePEInspectFD(fd, &pe))
            [failures addObject:[NSString stringWithFormat:@"The selected file is not a structurally valid PE image (%s).", strerror(errno)]];
        else {
            if (pe.is_dll) [failures addObject:@"A DLL cannot be launched as an application. Select its executable instead."];
            if (pe.subsystem != 2 && pe.subsystem != 3)
                [failures addObject:@"This file does not target the Windows GUI or console subsystem (for example, it may be a driver or firmware image)."];
            if (pe.machine == 0x14c && !win32) [failures addObject:@"This x86 application needs the WoW64/FEX runtime selection."];
            if (pe.machine == 0x8664 && !x64) [failures addObject:@"This x64 application needs the translated x64 runtime selection."];
            if ((pe.machine == 0xa641 || pe.machine == 0xa64e) && !x64)
                [failures addObject:@"This ARM64EC/ARM64X application needs the translated x64 runtime selection."];
            if (pe.machine != 0x14c && pe.machine != 0x8664 && pe.machine != 0xaa64 && pe.machine != 0xa641 && pe.machine != 0xa64e)
                [failures addObject:@"This PE machine type is not advertised by the current Juice runtime."];
            if (pe.managed) [warnings addObject:@"A CLR header is present. .NET/Mono dependencies and AnyCPU behavior still need application-specific validation."];
        }
        close(fd);
    }
#ifdef JUICE_SIDESTORE
    NSArray<NSString *> *executables = @[];
    if (pe.machine == 0x14c || win32)
        [failures addObject:@"This SideStore backend supports 64-bit guests only. A 32-bit guest requires a low-address-space design that does not depend on a jailbreak helper."];
    NSString *manifestPath = [runtime stringByAppendingPathComponent:@"Runtime.json"];
    NSData *manifestData = [NSData dataWithContentsOfFile:manifestPath options:0 error:nil];
    NSDictionary *manifest = manifestData.length <= 65536 ? [NSJSONSerialization JSONObjectWithData:manifestData ?: [NSData data] options:0 error:nil] : nil;
    if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"backend"] isEqual:@"embedded-sidestore"] || ![manifest[@"abi"] isEqual:@1])
        [failures addObject:@"The selected data runtime is not an ABI-compatible SideStore embedded runtime."];
    for (NSString *name in @[@"JuiceRuntimeSupport", @"JuiceNTDLL", @"JuiceWineServer", @"JuiceWin32U", @"JuiceWineIOS"]) {
        NSString *relative = [NSString stringWithFormat:@"%@.framework/%@", name, name];
        NSString *framework = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:relative];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:framework error:nil];
        if (![NSFileManager.defaultManager isReadableFileAtPath:framework] || ![attributes[NSFileSize] unsignedLongLongValue])
            [failures addObject:[@"Missing embedded framework: " stringByAppendingString:relative]];
    }
    [warnings addObject:@"One Windows process is hosted inside Juice. Guest child processes and a second runtime session require a different backend or an app restart. Physical-device execution is not certified by preflight."];
#else
    NSArray<NSString *> *executables = @[@"build/wine-ios/loader/wine", @"build/wine-ios/server/wineserver",
        @"tools/grape-trace-parent", @"tools/grape-nested-wrapper"];
#endif
    NSMutableArray<NSString *> *modules = [NSMutableArray arrayWithObject:@"runtime/lib/wine/aarch64-windows/ntdll.dll"];
    if (x64) [modules addObject:@"runtime/lib/wine/aarch64-windows/libarm64ecfex.dll"];
    if (win32) [modules addObjectsFromArray:@[@"runtime/lib/wine/aarch64-windows/libwow64fex.dll", @"runtime/lib/wine/i386-windows/ntdll.dll"]];
    NSFileManager *files = NSFileManager.defaultManager;
    if (!runtime.length) [failures addObject:@"No runtime was selected."];
    else {
        for (NSString *relative in executables) {
            NSString *path = [runtime stringByAppendingPathComponent:relative];
            BOOL directory = NO;
            if (![files fileExistsAtPath:path isDirectory:&directory] || directory || ![files isExecutableFileAtPath:path])
                [failures addObject:[@"Missing or non-executable runtime helper: " stringByAppendingString:relative]];
        }
        for (NSString *relative in modules) {
            NSString *path = [runtime stringByAppendingPathComponent:relative];
            BOOL directory = NO;
            NSDictionary *attributes = [files attributesOfItemAtPath:path error:nil];
            if (![files fileExistsAtPath:path isDirectory:&directory] || directory ||
                ![files isReadableFileAtPath:path] || ![attributes[NSFileSize] unsignedLongLongValue])
                [failures addObject:[@"Missing or unreadable runtime component: " stringByAppendingString:relative]];
        }
    }
    if (x64 || win32) [warnings addObject:@"CPU translation, JIT authorization, and performance have not been certified by this preflight."];
    return @{@"schema_version": @1, @"machine": @(pe.machine),
             @"architecture": [NSString stringWithUTF8String:JuicePEMachineName(pe.machine)],
             @"managed": @(pe.managed), @"can_launch": @(failures.count == 0),
             @"failures": failures, @"warnings": warnings};
}
