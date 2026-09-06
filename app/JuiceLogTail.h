#import <Foundation/Foundation.h>

/* Snapshot the opened inode's size, not the path's (which can rotate between
 * open and stat). A bounded read cannot chase a concurrently growing log. */
static inline NSData *JuiceBoundedLogTail(NSString *path, NSUInteger limit)
{
    if(!path.length||!limit)return nil;
    NSFileHandle *handle=[NSFileHandle fileHandleForReadingAtPath:path];
    if(!handle)return nil;
    NSData *data=nil;
    @try
    {
        unsigned long long size=[handle seekToEndOfFile];
        NSUInteger length=(NSUInteger)MIN(size,(unsigned long long)limit);
        [handle seekToFileOffset:size-length];
        data=[handle readDataOfLength:length];
        [handle closeFile];
    }
    @catch(__unused NSException *exception)
    {
        @try{[handle closeFile];}@catch(__unused NSException *closeException){}
        return nil;
    }
    return data.length?data:nil;
}
