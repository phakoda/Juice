#import "../JuiceLogHardening.m"
#import "../JuiceLogTail.h"
#import <assert.h>

@interface TestLogOwner : NSObject
@property(nonatomic,strong) NSString *persistentLogPath;
@property(nonatomic,strong) NSFileHandle *persistentLogHandle;
@end
@implementation TestLogOwner
@end
static void append(id owner,SEL selector,NSString *text)
{
    (void)selector;
    [((TestLogOwner *)owner).persistentLogHandle writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
}
int main(void)
{
    @autoreleasepool
    {
        NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
        TestLogOwner *owner=[TestLogOwner new];
        owner.persistentLogPath=[directory stringByAppendingPathComponent:@"Juice.log"];
        assert([NSFileManager.defaultManager createFileAtPath:owner.persistentLogPath contents:nil attributes:nil]);
        owner.persistentLogHandle=[NSFileHandle fileHandleForWritingAtPath:owner.persistentLogPath];
        JuiceLogOriginalAppend=append;
        NSString *large=[@"x" stringByPaddingToLength:20*1024*1024 withString:@"x" startingAtIndex:0];
        JuiceBoundedAppend(owner,NSSelectorFromString(@"append:"),large);
        assert(JuiceLogFileSize(owner.persistentLogPath)<=JuicePersistentLogSegmentBytes);
        assert(JuiceLogFileSize(JuicePreviousLogPath(owner.persistentLogPath))<=JuicePersistentLogSegmentBytes);
        assert([objc_getAssociatedObject(owner,&JuiceLogRotationsKey) unsignedIntegerValue]>=2);
        puts("PASS oversized append cannot exceed either log segment");
        NSString *chunk=[@"🙂" stringByPaddingToLength:131072 withString:@"🙂" startingAtIndex:0];
        dispatch_apply(80,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^(size_t index){
            (void)index;JuiceBoundedAppend(owner,NSSelectorFromString(@"append:"),chunk);
        });
        [owner.persistentLogHandle synchronizeFile];
        for(NSString *path in @[owner.persistentLogPath,JuicePreviousLogPath(owner.persistentLogPath)])
        {
            assert(JuiceLogFileSize(path)<=JuicePersistentLogSegmentBytes);
            assert([[NSString alloc] initWithData:[NSData dataWithContentsOfFile:path] encoding:NSUTF8StringEncoding]);
        }
        puts("PASS concurrent Unicode appends and rotations remain bounded");
        NSData *tail=JuiceBoundedLogTail(owner.persistentLogPath,64);
        assert(tail.length<=64 && tail.length>0);
        assert(JuiceBoundedLogTail(owner.persistentLogPath,0)==nil);
        assert(JuiceBoundedLogTail([directory stringByAppendingPathComponent:@"absent"],64)==nil);
        assert(fcntl(owner.persistentLogHandle.fileDescriptor,F_GETFD)&FD_CLOEXEC);
        puts("PASS bounded export tail and rotated descriptor hygiene");
        [owner.persistentLogHandle closeFile];
        assert([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        puts("JUICE_LOG_RETENTION_TESTS_OK");
    }
}
