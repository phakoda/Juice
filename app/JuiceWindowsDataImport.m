#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

/* User-facing import/launch support for Windows installer and data files that
 * are not themselves PE executables. This is adapted to current main's runtime
 * flags: when experimental translation is enabled, native helper EXEs run from
 * Grape-X64 with both x64 and WoW64 translators available for nested children. */

static void (*JuiceDataOriginalPicker)(id,SEL,UIDocumentPickerViewController *,NSArray<NSURL *> *);
static void (*JuiceDataOriginalViewDidLoad)(id,SEL);

static id JuiceDataValue(id object,NSString *key){@try{return [object valueForKey:key];}@catch(__unused NSException *e){return nil;}}
static void JuiceDataSetValue(id object,NSString *key,id value){@try{[object setValue:value forKey:key];}@catch(__unused NSException *e){}}
static void JuiceDataAppend(id self,NSString *line){SEL s=NSSelectorFromString(@"append:");if([self respondsToSelector:s])((void(*)(id,SEL,id))objc_msgSend)(self,s,line);}
static void JuiceDataReject(id self,NSString *message){SEL s=NSSelectorFromString(@"rejectLaunch:");if([self respondsToSelector:s])((void(*)(id,SEL,id))objc_msgSend)(self,s,message);else JuiceDataAppend(self,message);}

static NSString *JuiceDataDocuments(void)
{
    NSArray<NSString *> *paths=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES);
    return paths.firstObject.length?paths.firstObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
}

static NSString *JuiceDataImportRoot(void)
{
    return [[[JuiceDataDocuments() stringByAppendingPathComponent:@"JuiceData"]
             stringByAppendingPathComponent:@"Imported"] stringByStandardizingPath];
}

static NSString *JuiceDataCopyImport(NSURL *url,NSError **error)
{
    NSString *root=JuiceDataImportRoot();
    if(![NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:error])return nil;
    NSString *name=url.lastPathComponent.length?url.lastPathComponent:@"windows-file";
    NSString *destination=[root stringByAppendingPathComponent:name];
    if([NSFileManager.defaultManager fileExistsAtPath:destination])
    {
        NSString *extension=name.pathExtension, *stem=name.stringByDeletingPathExtension.length?name.stringByDeletingPathExtension:@"windows-file";
        NSString *unique=extension.length?[NSString stringWithFormat:@"%@-%@.%@",stem,NSUUID.UUID.UUIDString,extension]:[NSString stringWithFormat:@"%@-%@",stem,NSUUID.UUID.UUIDString];
        destination=[root stringByAppendingPathComponent:unique];
    }
    [NSFileManager.defaultManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:destination] error:error];
    return *error?nil:destination;
}

static NSString *JuiceDataWindowsPath(NSString *path)
{
    return [@"Z:" stringByAppendingString:[path stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
}

static BOOL JuiceDataTranslatedRuntimeSafe(id self,NSString **detail)
{
    NSString *runtime=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Grape-X64"];
    SEL safety=NSSelectorFromString(@"translatedRuntimeIsSafe:detail:");
    if(![self respondsToSelector:safety])
    {
        if(detail)*detail=@"Translation safety validation is unavailable.";
        return NO;
    }
    BOOL safe=((BOOL(*)(id,SEL,id,NSString **))objc_msgSend)(self,safety,runtime,detail);
    if(!safe)return NO;
    NSArray<NSString *> *required=@[
        @"runtime/lib/wine/aarch64-windows/libarm64ecfex.dll",
        @"runtime/lib/wine/aarch64-windows/libwow64fex.dll",
        @"runtime/lib/wine/i386-windows/ntdll.dll"
    ];
    for(NSString *relative in required)
    {
        if(![NSFileManager.defaultManager fileExistsAtPath:[runtime stringByAppendingPathComponent:relative]])
        {
            if(detail)*detail=[NSString stringWithFormat:@"%@ is missing.",relative];
            return NO;
        }
    }
    return YES;
}

static BOOL JuiceDataConfigureHelperRuntime(id self,BOOL translated)
{
    if(translated)
    {
        NSString *detail=nil;
        if(!JuiceDataTranslatedRuntimeSafe(self,&detail))
        {
            JuiceDataReject(self,[NSString stringWithFormat:@"Juice cannot run this helper in the translated runtime. %@",detail?:@"Required translation components are unavailable."]);
            return NO;
        }
        JuiceDataSetValue(self,@"usingX64",@YES);
        JuiceDataSetValue(self,@"usingWin32",@YES);
    }
    else
    {
        JuiceDataSetValue(self,@"usingX64",@NO);
        JuiceDataSetValue(self,@"usingWin32",@NO);
    }
    return YES;
}

static void JuiceDataLaunchHelper(id self,NSString *helper,NSString *arguments,NSString *kind,NSString *local,NSString *windowsPath)
{
    UITextField *exe=JuiceDataValue(self,@"exeField"), *args=JuiceDataValue(self,@"argsField");
    UISegmentedControl *mode=JuiceDataValue(self,@"mode");
    if(![exe isKindOfClass:UITextField.class]||![args isKindOfClass:UITextField.class])
    {JuiceDataAppend(self,@"WINDOWS_DATA_IMPORT_FAILED reason=launcher-unavailable\n");return;}

    BOOL translated=[JuiceDataValue(self,@"experimentalX64") boolValue];
    if(!JuiceDataConfigureHelperRuntime(self,translated))return;
    exe.text=helper;args.text=arguments;if([mode isKindOfClass:UISegmentedControl.class])mode.selectedSegmentIndex=0;
    JuiceDataAppend(self,[NSString stringWithFormat:@"WINDOWS_DATA_IMPORT_READY kind=%@ local=%@ windows=%@ helper=%@ translated=%d wow64=%d\n",kind,local,windowsPath,helper,translated,translated]);
    SEL launch=NSSelectorFromString(@"launchTapped");
    if([self respondsToSelector:launch])((void(*)(id,SEL))objc_msgSend)(self,launch);
    int server=[JuiceDataValue(self,@"server") intValue];
    JuiceDataSetValue(self,@"serverUsingX64",@(translated&&server>0));
}

static void JuiceDataPicked(id self,SEL _cmd,UIDocumentPickerViewController *controller,NSArray<NSURL *> *urls)
{
    NSURL *url=urls.firstObject;
    BOOL control=controller==JuiceDataValue(self,@"controlPicker");
    NSString *extension=url.pathExtension.lowercaseString;
    BOOL msi=[extension isEqualToString:@"msi"];
    BOOL batch=[extension isEqualToString:@"bat"]||[extension isEqualToString:@"cmd"];
    BOOL registry=[extension isEqualToString:@"reg"];
    if(!url||control||(!msi&&!batch&&!registry))
    {
        if(JuiceDataOriginalPicker)JuiceDataOriginalPicker(self,_cmd,controller,urls);
        return;
    }

    BOOL scoped=[url startAccessingSecurityScopedResource];NSError *error=nil;
    NSString *destination=JuiceDataCopyImport(url,&error);
    if(scoped)[url stopAccessingSecurityScopedResource];
    if(!destination.length||error)
    {
        JuiceDataAppend(self,[NSString stringWithFormat:@"WINDOWS_DATA_IMPORT_FAILED file=%@ error=%@\n",url.lastPathComponent?:@"",error.localizedDescription?:@"copy failed"]);
        return;
    }

    NSString *windows=JuiceDataWindowsPath(destination);
    if(msi)
        JuiceDataLaunchHelper(self,@"msiexec.exe",[NSString stringWithFormat:@"/i \"%@\"",windows],@"msi",destination,windows);
    else if(batch)
        JuiceDataLaunchHelper(self,@"cmd.exe",[NSString stringWithFormat:@"/c \"%@\"",windows],@"batch",destination,windows);
    else
        JuiceDataLaunchHelper(self,@"reg.exe",[NSString stringWithFormat:@"import \"%@\"",windows],@"registry",destination,windows);
}

static void JuiceRenameDataPickerButton(UIView *view)
{
    if([view isKindOfClass:UIButton.class])
    {
        UIButton *button=(UIButton *)view;NSString *title=[button titleForState:UIControlStateNormal];
        if([title isEqualToString:@"Choose EXE or Portable ZIP"]||[title isEqualToString:@"Choose EXE, MSI or Portable ZIP"])
            [button setTitle:@"Choose Windows App, Installer or ZIP" forState:UIControlStateNormal];
    }
    for(UIView *subview in view.subviews)JuiceRenameDataPickerButton(subview);
}

static void JuiceDataViewDidLoad(id self,SEL _cmd)
{
    if(JuiceDataOriginalViewDidLoad)JuiceDataOriginalViewDidLoad(self,_cmd);
    if([self isKindOfClass:UIViewController.class])JuiceRenameDataPickerButton(((UIViewController *)self).view);
}

__attribute__((constructor(360)))
static void JuiceInstallWindowsDataImport(void)
{
    Class cls=NSClassFromString(@"JuiceController");if(!cls)return;
    Method picker=class_getInstanceMethod(cls,NSSelectorFromString(@"documentPicker:didPickDocumentsAtURLs:"));
    if(picker)JuiceDataOriginalPicker=(void(*)(id,SEL,UIDocumentPickerViewController *,NSArray<NSURL *> *))method_setImplementation(picker,(IMP)JuiceDataPicked);
    Method view=class_getInstanceMethod(cls,@selector(viewDidLoad));
    if(view)JuiceDataOriginalViewDidLoad=(void(*)(id,SEL))method_setImplementation(view,(IMP)JuiceDataViewDidLoad);
}
