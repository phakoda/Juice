#import <UIKit/UIKit.h>
#import <errno.h>
#import <fcntl.h>
#import <objc/message.h>
#import <objc/runtime.h>

static const unsigned long long JuicePersistentLogSegmentBytes=8ull*1024ull*1024ull;
static void (*JuiceLogOriginalAppend)(id,SEL,NSString *);
static void (*JuiceLogOriginalViewDidLoad)(id,SEL);
static char JuiceLogByteCountKey;
static char JuiceLogRotationsKey;

static id JuiceLogValue(id object,NSString *key)
{
    @try{return [object valueForKey:key];}
    @catch(__unused NSException *exception){return nil;}
}
static void JuiceLogSetValue(id object,NSString *key,id value)
{
    @try{[object setValue:value forKey:key];}
    @catch(__unused NSException *exception){}
}
static NSString *JuicePreviousLogPath(NSString *path)
{
    return path.length?[path stringByAppendingString:@".previous"]:@"";
}
static unsigned long long JuiceLogFileSize(NSString *path)
{
    NSNumber *size=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileSize];
    return size.unsignedLongLongValue;
}
static void JuiceLogMarkCloexec(NSFileHandle *handle)
{
    if(![handle isKindOfClass:NSFileHandle.class])return;
    int fd=handle.fileDescriptor;if(fd<0)return;
    int flags=fcntl(fd,F_GETFD);if(flags>=0)fcntl(fd,F_SETFD,flags|FD_CLOEXEC);
}
static BOOL JuiceRotatePersistentLog(id self,NSString *path)
{
    NSFileHandle *handle=JuiceLogValue(self,@"persistentLogHandle");
    if(!path.length||![handle isKindOfClass:NSFileHandle.class])return NO;

    @try{[handle synchronizeFile];[handle closeFile];}
    @catch(__unused NSException *exception){}
    JuiceLogSetValue(self,@"persistentLogHandle",nil);

    NSFileManager *files=NSFileManager.defaultManager;
    NSString *previous=JuicePreviousLogPath(path);
    [files removeItemAtPath:previous error:nil];
    NSError *moveError=nil;
    if([files fileExistsAtPath:path]&&![files moveItemAtPath:path toPath:previous error:&moveError])
    {
        /* If rename failed, truncate the current segment rather than allowing
         * an unbounded log to continue consuming the container. */
        [files removeItemAtPath:path error:nil];
    }

    NSString *marker=[NSString stringWithFormat:
        @"JUICE_LOG_ROTATED previous=%@ previous_bytes=%llu rename_error=%@\n",
        previous,JuiceLogFileSize(previous),moveError.localizedDescription?:@"none"];
    NSData *markerData=[marker dataUsingEncoding:NSUTF8StringEncoding];
    if(![files createFileAtPath:path contents:markerData attributes:nil])return NO;
    NSFileHandle *replacement=[NSFileHandle fileHandleForWritingAtPath:path];
    if(!replacement)return NO;
    @try{[replacement seekToEndOfFile];}@catch(__unused NSException *exception){}
    JuiceLogMarkCloexec(replacement);
    JuiceLogSetValue(self,@"persistentLogHandle",replacement);
    objc_setAssociatedObject(self,&JuiceLogByteCountKey,@(markerData.length),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSUInteger rotations=[objc_getAssociatedObject(self,&JuiceLogRotationsKey) unsignedIntegerValue]+1;
    objc_setAssociatedObject(self,&JuiceLogRotationsKey,@(rotations),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}
static void JuiceBoundedAppend(id self,SEL _cmd,NSString *text)
{
    if(JuiceLogOriginalAppend)JuiceLogOriginalAppend(self,_cmd,text);
    if(!text.length)return;
    NSUInteger added=[text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if(!added)return;

    @synchronized(self)
    {
        unsigned long long bytes=[objc_getAssociatedObject(self,&JuiceLogByteCountKey) unsignedLongLongValue];
        bytes+=added;
        objc_setAssociatedObject(self,&JuiceLogByteCountKey,@(bytes),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if(bytes<JuicePersistentLogSegmentBytes)return;
        NSString *path=JuiceLogValue(self,@"persistentLogPath");
        JuiceRotatePersistentLog(self,path);
    }
}
static void JuiceLogViewDidLoad(id self,SEL _cmd)
{
    if(JuiceLogOriginalViewDidLoad)JuiceLogOriginalViewDidLoad(self,_cmd);
    NSString *path=JuiceLogValue(self,@"persistentLogPath");
    if(!path.length)return;

    /* main.m starts every app session with a fresh current log. A previous
     * segment from an older session is no longer part of this run. */
    [NSFileManager.defaultManager removeItemAtPath:JuicePreviousLogPath(path) error:nil];
    objc_setAssociatedObject(self,&JuiceLogByteCountKey,@(JuiceLogFileSize(path)),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self,&JuiceLogRotationsKey,@0,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    JuiceLogMarkCloexec(JuiceLogValue(self,@"persistentLogHandle"));

    JuiceBoundedAppend(self,NSSelectorFromString(@"append:"),
        [NSString stringWithFormat:@"LOG_RETENTION_READY segment_bytes=%llu segments=2 max_bytes=%llu\n",
         JuicePersistentLogSegmentBytes,JuicePersistentLogSegmentBytes*2ull]);
}

__attribute__((constructor(430)))
static void JuiceInstallLogHardening(void)
{
    Class cls=NSClassFromString(@"JuiceController");if(!cls)return;
    Method append=class_getInstanceMethod(cls,NSSelectorFromString(@"append:"));
    if(append)JuiceLogOriginalAppend=(void(*)(id,SEL,NSString *))method_setImplementation(append,(IMP)JuiceBoundedAppend);
    Method view=class_getInstanceMethod(cls,@selector(viewDidLoad));
    if(view)JuiceLogOriginalViewDidLoad=(void(*)(id,SEL))method_setImplementation(view,(IMP)JuiceLogViewDidLoad);
}
