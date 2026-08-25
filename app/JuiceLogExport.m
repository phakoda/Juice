#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

/*
 * Keep log exporting isolated from the main controller implementation. Juice's
 * main UI owns a persistent log file containing controller events and the child
 * Wine/FEX stdout+stderr stream. Runtime hardening may rotate that file into a
 * single `.previous` segment; export combines both retained segments.
 *
 * Do not hand /var/mobile/Documents URLs directly to UIActivityViewController.
 * Juice is intentionally unsandboxed under TrollStore and those paths are not
 * normal app-container document URLs. Share extensions can require a sandbox
 * extension for every URL they receive, which makes that route unnecessarily
 * fragile. Instead create an immutable snapshot in Juice's temporary directory
 * and ask the system document picker to copy it to the user's chosen location.
 */
static const unsigned long long JuiceLogExportTailBytes=8ull*1024ull*1024ull;

static NSData *JuiceReadLogTail(NSString *path)
{
    if(!path.length)return nil;
    NSFileHandle *handle=[NSFileHandle fileHandleForReadingAtPath:path];
    if(!handle)return nil;
    unsigned long long size=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileSize;
    unsigned long long start=size>JuiceLogExportTailBytes?size-JuiceLogExportTailBytes:0;
    NSData *data=nil;
    @try
    {
        if(start)[handle seekToFileOffset:start];
        data=[handle readDataToEndOfFile];
        [handle closeFile];
    }
    @catch(__unused NSException *exception)
    {
        @try{[handle closeFile];}@catch(__unused NSException *closeException){}
        return nil;
    }
    return data.length?data:nil;
}

static NSData *JuiceCombinedLogContents(NSString *source)
{
    if(!source.length)return nil;
    NSArray<NSString *> *paths=@[[source stringByAppendingString:@".previous"],source];
    NSMutableData *combined=[NSMutableData data];
    for(NSString *path in paths)
    {
        NSData *part=JuiceReadLogTail(path);
        if(!part.length)continue;
        if(combined.length)
        {
            NSData *separator=[@"\n--- JUICE LOG SEGMENT ---\n" dataUsingEncoding:NSUTF8StringEncoding];
            [combined appendData:separator];
        }
        [combined appendData:part];
    }
    return combined.length?combined:nil;
}

static void JuiceCleanupLogExportStaging(NSFileManager *files,NSURL *temporaryRoot)
{
    NSArray<NSURL *> *children=[files contentsOfDirectoryAtURL:temporaryRoot
                                   includingPropertiesForKeys:nil
                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                        error:nil];
    for(NSURL *child in children)
        if([child.lastPathComponent hasPrefix:@"JuiceLogExport-"])
            [files removeItemAtURL:child error:nil];
}

@interface JuiceController : UIViewController
@end

@interface JuiceController (JuiceLogExport)
- (void)juice_logExport_viewDidLoad;
- (void)juice_exportLogTapped:(UIButton *)sender;
- (void)juice_showLogExportError:(NSString *)message;
@end

@implementation JuiceController (JuiceLogExport)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class controller = NSClassFromString(@"JuiceController");
        Method original = class_getInstanceMethod(controller, @selector(viewDidLoad));
        Method replacement = class_getInstanceMethod(controller, @selector(juice_logExport_viewDidLoad));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

- (void)juice_logExport_viewDidLoad
{
    /* Swizzled: this invokes JuiceController's original -viewDidLoad. */
    [self juice_logExport_viewDidLoad];

    id value = nil;
    @try { value = [self valueForKey:@"form"]; }
    @catch (__unused NSException *exception) {}
    if (![value isKindOfClass:UIStackView.class]) return;

    UIStackView *form = value;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"Export Full Log" forState:UIControlStateNormal];
    button.accessibilityIdentifier = @"juice.export-log";
    [button addTarget:self action:@selector(juice_exportLogTapped:)
     forControlEvents:UIControlEventTouchUpInside];
    [form addArrangedSubview:button];
}

- (void)juice_showLogExportError:(NSString *)message
{
    void (^show)(void) = ^{
        if (self.presentedViewController) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Log export failed"
         message:message.length ? message : @"Juice could not create the log export."
         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
         style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    };
    if (NSThread.isMainThread) show();
    else dispatch_async(dispatch_get_main_queue(), show);
}

- (void)juice_exportLogTapped:(UIButton *)sender
{
    /* UI presentation must stay on the main thread even if this selector is
       ever invoked programmatically from one of Juice's worker queues. */
    if (!NSThread.isMainThread)
    {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf juice_exportLogTapped:sender];
        });
        return;
    }

    /* Never attempt to stack another exporter on top of an existing modal. */
    if (self.presentedViewController)
    {
        SEL appendSelector = NSSelectorFromString(@"append:");
        if ([self respondsToSelector:appendSelector])
            ((void (*)(id, SEL, id))objc_msgSend)(self, appendSelector,
             @"LOG_EXPORT_REJECTED reason=modal-already-presented\n");
        return;
    }

    NSString *source = nil;
    @try { source = [self valueForKey:@"persistentLogPath"]; }
    @catch (__unused NSException *exception) {}

    /* Read only the retained tail of each segment. This remains bounded even
       when exporting a log created by an older Juice build without rotation. */
    NSData *contents = JuiceCombinedLogContents(source);
    if (!contents.length)
    {
        id logView = nil;
        @try { logView = [self valueForKey:@"log"]; }
        @catch (__unused NSException *exception) {}
        if ([logView isKindOfClass:UITextView.class])
            contents = [[(UITextView *)logView text] dataUsingEncoding:NSUTF8StringEncoding];
    }

    if (!contents.length)
    {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No log to export"
         message:@"Juice has not recorded any log output yet."
         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [formatter stringFromDate:NSDate.date];

    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *temporaryRoot = files.temporaryDirectory;
    JuiceCleanupLogExportStaging(files,temporaryRoot);
    NSURL *stagingDirectory = [temporaryRoot URLByAppendingPathComponent:
     [NSString stringWithFormat:@"JuiceLogExport-%@", NSUUID.UUID.UUIDString]
     isDirectory:YES];
    NSURL *snapshotURL = [stagingDirectory URLByAppendingPathComponent:
     [NSString stringWithFormat:@"Juice-%@.txt", stamp]
     isDirectory:NO];

    NSError *error = nil;
    if (![files createDirectoryAtURL:stagingDirectory
          withIntermediateDirectories:YES attributes:nil error:&error] ||
        ![contents writeToURL:snapshotURL options:NSDataWritingAtomic error:&error])
    {
        [self juice_showLogExportError:error.localizedDescription];
        return;
    }

    UIDocumentPickerViewController *picker = nil;
    if (@available(iOS 14.0, *))
    {
        picker = [[UIDocumentPickerViewController alloc]
         initForExportingURLs:@[snapshotURL] asCopy:YES];
    }
    else
    {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        picker = [[UIDocumentPickerViewController alloc]
         initWithURL:snapshotURL inMode:UIDocumentPickerModeExportToService];
#pragma clang diagnostic pop
    }

    if (!picker)
    {
        [self juice_showLogExportError:@"iOS could not create the document exporter."];
        return;
    }

    picker.modalPresentationStyle = UIModalPresentationFormSheet;

    /* Do not set self as the export picker's delegate. JuiceController's
       existing document-picker delegate is the program importer and would
       otherwise try to interpret the exported .txt as a program selection. */
    @try
    {
        [self presentViewController:picker animated:YES completion:nil];
    }
    @catch (NSException *exception)
    {
        [self juice_showLogExportError:exception.reason ?: @"iOS rejected the document exporter."];
        return;
    }

    SEL appendSelector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:appendSelector])
    {
        NSString *message = [NSString stringWithFormat:
         @"LOG_EXPORT_PICKER_OPEN snapshot=%@ bytes=%lu retained_segments=2 bounded=1\n",
         snapshotURL.path, (unsigned long)contents.length];
        ((void (*)(id, SEL, id))objc_msgSend)(self, appendSelector, message);
    }
}

@end
