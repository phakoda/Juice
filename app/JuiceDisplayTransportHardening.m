#import <UIKit/UIKit.h>
#import <errno.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <signal.h>
#import <string.h>
#import <sys/resource.h>
#import <sys/socket.h>
#import <unistd.h>

#define JUICE_DISPLAY_MAGIC 0x4a554943u
#define JUICE_DISPLAY_HELLO 1u
#define JUICE_DISPLAY_WINDOW 3u
#define JUICE_DISPLAY_DESTROY 4u
#define JUICE_DISPLAY_FRAME 5u
#define JUICE_DISPLAY_DIRTY 0x20000000u
#define JUICE_DISPLAY_MAX_BYTES (128u * 1024u * 1024u)
#define JUICE_DISPLAY_MAX_DESKTOP_DIMENSION 8192
#define JUICE_DISPLAY_MAX_DESKTOP_PIXELS (4096ULL * 4096ULL)
#define JUICE_DISPLAY_MAX_WINDOW_DIMENSION 8192
#define JUICE_DISPLAY_MAX_WINDOW_PIXELS (4096ULL * 4096ULL)
#define JUICE_DISPLAY_MAX_WINDOW_ORIGIN 131072

typedef struct
{
    uint32_t magic, type, size;
    uint64_t hwnd;
    int32_t x, y, width, height;
    uint32_t stride, flags;
} JuiceDisplayMsg;

@interface JuiceDisplayFramebuffer : NSObject
@property(nonatomic,strong) NSMutableData *bytes;
@property(nonatomic) uint64_t hwnd;
@property(nonatomic) int32_t width,height;
@property(nonatomic) uint32_t stride;
@property(nonatomic) int clientFD;
@property(nonatomic) pid_t peerPID;
@property(nonatomic) NSUInteger generation,received,rendered,coalesced;
@property(nonatomic) BOOL scheduled,firstPending,invalidated;
@end
@implementation JuiceDisplayFramebuffer
@end

static char JuiceDisplayFramesKey;

static id JuiceDisplayValue(id object, NSString *key)
{
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceDisplaySetValue(id object, NSString *key, id value)
{
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static void JuiceDisplayAppend(id self, NSString *line)
{
    SEL selector=NSSelectorFromString(@"append:");
    if([self respondsToSelector:selector])
        ((void (*)(id,SEL,id))objc_msgSend)(self,selector,line);
}

static NSMutableDictionary<NSNumber *,JuiceDisplayFramebuffer *> *JuiceDisplayFrames(id self)
{
    NSMutableDictionary *frames=objc_getAssociatedObject(self,&JuiceDisplayFramesKey);
    if(frames)return frames;
    @synchronized(self)
    {
        frames=objc_getAssociatedObject(self,&JuiceDisplayFramesKey);
        if(!frames)
        {
            frames=[NSMutableDictionary dictionary];
            objc_setAssociatedObject(self,&JuiceDisplayFramesKey,frames,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return frames;
}

static BOOL JuiceDisplayReadAll(int fd,void *buffer,size_t length)
{
    uint8_t *cursor=buffer;
    while(length)
    {
        ssize_t count=read(fd,cursor,length);
        if(count<0&&errno==EINTR)continue;
        if(count<=0)return NO;
        cursor+=count;
        length-=(size_t)count;
    }
    return YES;
}

static BOOL JuiceDimensionsValid(int32_t width,int32_t height,int32_t maxDimension,uint64_t maxPixels)
{
    if(width<=0||height<=0||width>maxDimension||height>maxDimension)return NO;
    return (uint64_t)(uint32_t)width*(uint32_t)height<=maxPixels;
}

static BOOL JuiceDesktopGeometryValid(JuiceDisplayMsg message)
{
    return JuiceDimensionsValid(message.width,message.height,
                                JUICE_DISPLAY_MAX_DESKTOP_DIMENSION,
                                JUICE_DISPLAY_MAX_DESKTOP_PIXELS);
}

static BOOL JuiceWindowGeometryValid(JuiceDisplayMsg message)
{
    if(message.width<=0&&message.height<=0)return YES;
    if(!JuiceDimensionsValid(message.width,message.height,
                             JUICE_DISPLAY_MAX_WINDOW_DIMENSION,
                             JUICE_DISPLAY_MAX_WINDOW_PIXELS))return NO;
    return message.x>=-JUICE_DISPLAY_MAX_WINDOW_ORIGIN&&message.x<=JUICE_DISPLAY_MAX_WINDOW_ORIGIN&&
           message.y>=-JUICE_DISPLAY_MAX_WINDOW_ORIGIN&&message.y<=JUICE_DISPLAY_MAX_WINDOW_ORIGIN;
}

static BOOL JuiceFullHeaderValid(JuiceDisplayMsg message)
{
    if(!JuiceDimensionsValid(message.width,message.height,
                             JUICE_DISPLAY_MAX_WINDOW_DIMENSION,
                             JUICE_DISPLAY_MAX_WINDOW_PIXELS))return NO;
    if((uint64_t)(uint32_t)message.width*4u>message.stride)return NO;
    uint64_t expected=(uint64_t)message.stride*(uint32_t)message.height;
    return expected==message.size&&expected<=JUICE_DISPLAY_MAX_BYTES;
}

static BOOL JuiceDirtyHeaderValid(JuiceDisplayMsg message)
{
    if(!JuiceDimensionsValid(message.width,message.height,
                             JUICE_DISPLAY_MAX_WINDOW_DIMENSION,
                             JUICE_DISPLAY_MAX_WINDOW_PIXELS)||message.x<0||message.y<0)return NO;
    uint64_t row=(uint64_t)(uint32_t)message.width*4u;
    if(row>message.stride)return NO;
    uint64_t expected=(uint64_t)message.stride*(uint32_t)message.height;
    return expected==message.size&&expected<=JUICE_DISPLAY_MAX_BYTES;
}

static void JuiceInvalidateHWND(id self,uint64_t hwnd)
{
    NSMutableDictionary *frames=JuiceDisplayFrames(self);
    @synchronized(frames)
    {
        JuiceDisplayFramebuffer *frame=frames[@(hwnd)];
        if(frame)@synchronized(frame){frame.invalidated=YES;}
        [frames removeObjectForKey:@(hwnd)];
    }
}

static void JuiceInvalidateClient(id self,int fd)
{
    NSMutableDictionary *frames=JuiceDisplayFrames(self);
    NSMutableArray<NSNumber *> *remove=[NSMutableArray array];
    __block NSUInteger received=0,rendered=0,coalesced=0;
    @synchronized(frames)
    {
        [frames enumerateKeysAndObjectsUsingBlock:^(NSNumber *key,JuiceDisplayFramebuffer *frame,BOOL *stop){
            (void)stop;
            @synchronized(frame)
            {
                if(frame.clientFD!=fd)return;
                frame.invalidated=YES;
                received+=frame.received;
                rendered+=frame.rendered;
                coalesced+=frame.coalesced;
                [remove addObject:key];
            }
        }];
        [frames removeObjectsForKeys:remove];
    }
    if(received)
        JuiceDisplayAppend(self,[NSString stringWithFormat:
            @"DISPLAY_COALESCE fd=%d received=%lu rendered=%lu merged=%lu windows=%lu\n",
            fd,(unsigned long)received,(unsigned long)rendered,(unsigned long)coalesced,
            (unsigned long)remove.count]);
}

static JuiceDisplayFramebuffer *JuiceApplyFull(id self,JuiceDisplayMsg message,NSMutableData *data,
                                                int fd,pid_t peerPID)
{
    if(!JuiceFullHeaderValid(message)||data.length!=message.size)return nil;
    NSMutableDictionary *frames=JuiceDisplayFrames(self);
    @synchronized(frames)
    {
        JuiceDisplayFramebuffer *frame=frames[@(message.hwnd)];
        if(frame)
        {
            @synchronized(frame)
            {
                if(!frame.invalidated&&frame.width==message.width&&frame.height==message.height&&
                   frame.stride==message.stride&&frame.bytes.length==data.length)
                {
                    memcpy(frame.bytes.mutableBytes,data.bytes,data.length);
                    frame.clientFD=fd;frame.peerPID=peerPID;frame.generation++;frame.received++;
                    return frame;
                }
                frame.invalidated=YES;
            }
        }
        frame=[JuiceDisplayFramebuffer new];
        frame.bytes=data;frame.hwnd=message.hwnd;frame.width=message.width;frame.height=message.height;
        frame.stride=message.stride;frame.clientFD=fd;frame.peerPID=peerPID;
        frame.generation=1;frame.received=1;
        frames[@(message.hwnd)]=frame;
        return frame;
    }
}

static JuiceDisplayFramebuffer *JuiceApplyDirty(id self,JuiceDisplayMsg message,NSData *data,
                                                 int fd,pid_t peerPID)
{
    if(!JuiceDirtyHeaderValid(message)||data.length!=message.size)return nil;
    NSMutableDictionary *frames=JuiceDisplayFrames(self);
    JuiceDisplayFramebuffer *frame;
    @synchronized(frames){frame=frames[@(message.hwnd)];}
    if(!frame)
    {
        JuiceDisplayAppend(self,[NSString stringWithFormat:
            @"DISPLAY_DIRTY_DROPPED hwnd=0x%llx reason=no-baseline\n",
            (unsigned long long)message.hwnd]);
        return nil;
    }
    @synchronized(frame)
    {
        if(frame.invalidated||
           (uint64_t)(uint32_t)message.x+(uint32_t)message.width>(uint32_t)frame.width||
           (uint64_t)(uint32_t)message.y+(uint32_t)message.height>(uint32_t)frame.height)
            return nil;
        size_t rowBytes=(size_t)(uint32_t)message.width*4u;
        uint8_t *destination=frame.bytes.mutableBytes;
        const uint8_t *source=data.bytes;
        for(int32_t row=0;row<message.height;row++)
            memcpy(destination+(size_t)(message.y+row)*frame.stride+(size_t)message.x*4u,
                   source+(size_t)row*message.stride,rowBytes);
        frame.clientFD=fd;frame.peerPID=peerPID;frame.generation++;frame.received++;
    }
    return frame;
}

static void JuiceDeliverFrame(id self,JuiceDisplayFramebuffer *frame);

static void JuiceScheduleFrame(id self,JuiceDisplayFramebuffer *frame,BOOL first)
{
    BOOL schedule=NO;
    @synchronized(frame)
    {
        if(frame.invalidated)return;
        if(first)frame.firstPending=YES;
        if(!frame.scheduled){frame.scheduled=YES;schedule=YES;}
        else frame.coalesced++;
    }
    if(schedule)dispatch_async(dispatch_get_main_queue(),^{JuiceDeliverFrame(self,frame);});
}

static void JuiceDeliverFrame(id self,JuiceDisplayFramebuffer *frame)
{
    NSData *snapshot;
    uint64_t hwnd;
    int32_t width,height;
    uint32_t stride;
    int fd;
    pid_t peerPID;
    NSUInteger generation;
    BOOL first;
    @synchronized(frame)
    {
        if(frame.invalidated){frame.scheduled=NO;return;}
        snapshot=[frame.bytes copy];hwnd=frame.hwnd;width=frame.width;height=frame.height;
        stride=frame.stride;fd=frame.clientFD;peerPID=frame.peerPID;
        generation=frame.generation;first=frame.firstPending;frame.firstPending=NO;frame.rendered++;
    }
    JuiceDisplayMsg message={JUICE_DISPLAY_MAGIC,JUICE_DISPLAY_FRAME,(uint32_t)snapshot.length,
                             hwnd,0,0,width,height,stride,0};
    SEL selector=NSSelectorFromString(@"presentFrameMessage:data:client:peerPID:first:");
    if([self respondsToSelector:selector])
        ((void (*)(id,SEL,JuiceDisplayMsg,NSData *,int,pid_t,BOOL))objc_msgSend)
            (self,selector,message,snapshot,fd,peerPID,first);
    BOOL again=NO;
    @synchronized(frame)
    {
        if(frame.invalidated)frame.scheduled=NO;
        else if(frame.generation!=generation)again=YES;
        else frame.scheduled=NO;
    }
    if(again)dispatch_async(dispatch_get_main_queue(),^{JuiceDeliverFrame(self,frame);});
}

static void JuiceHardenedReadClient(id self,SEL _cmd,int fd)
{
    (void)_cmd;
    pid_t peerPID=0;
    BOOL firstFrame=YES;
#ifdef SO_NOSIGPIPE
    int one=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
#endif
    for(;;)
    {
        @autoreleasepool
        {
            JuiceDisplayMsg message;
            if(!JuiceDisplayReadAll(fd,&message,sizeof(message)))break;
            if(message.magic!=JUICE_DISPLAY_MAGIC)
            {
                JuiceDisplayAppend(self,[NSString stringWithFormat:@"DISPLAY_PROTOCOL_REJECTED fd=%d reason=magic\n",fd]);
                break;
            }
            BOOL fixed=message.type==JUICE_DISPLAY_HELLO||message.type==JUICE_DISPLAY_WINDOW||
                       message.type==JUICE_DISPLAY_DESTROY;
            if(fixed&&message.size)
            {
                JuiceDisplayAppend(self,[NSString stringWithFormat:@"DISPLAY_PROTOCOL_REJECTED fd=%d reason=fixed-payload type=%u bytes=%u\n",fd,message.type,message.size]);
                break;
            }
            if(message.type==JUICE_DISPLAY_FRAME)
            {
                BOOL dirty=(message.flags&JUICE_DISPLAY_DIRTY)!=0;
                if(dirty?!JuiceDirtyHeaderValid(message):!JuiceFullHeaderValid(message))
                {
                    JuiceDisplayAppend(self,[NSString stringWithFormat:@"DISPLAY_PROTOCOL_REJECTED fd=%d reason=frame-geometry rect=%d,%d %dx%d stride=%u bytes=%u\n",fd,message.x,message.y,message.width,message.height,message.stride,message.size]);
                    break;
                }
            }
            else if(!fixed)
            {
                JuiceDisplayAppend(self,[NSString stringWithFormat:@"DISPLAY_PROTOCOL_REJECTED fd=%d reason=unknown-type type=%u\n",fd,message.type]);
                break;
            }
            if(message.type==JUICE_DISPLAY_HELLO&&!JuiceDesktopGeometryValid(message))
            {
                JuiceDisplayAppend(self,[NSString stringWithFormat:@"DISPLAY_GEOMETRY_REJECTED kind=desktop fd=%d size=%dx%d\n",fd,message.width,message.height]);
                break;
            }
            if(message.type==JUICE_DISPLAY_WINDOW&&!JuiceWindowGeometryValid(message))
            {
                JuiceDisplayAppend(self,[NSString stringWithFormat:@"DISPLAY_GEOMETRY_REJECTED kind=window fd=%d hwnd=0x%llx rect=%d,%d %dx%d\n",fd,(unsigned long long)message.hwnd,message.x,message.y,message.width,message.height]);
                break;
            }

            NSMutableData *data=nil;
            if(message.size)
            {
                data=[NSMutableData dataWithLength:message.size];
                if(!data||!JuiceDisplayReadAll(fd,data.mutableBytes,message.size))break;
            }
            if(message.type==JUICE_DISPLAY_HELLO)
            {
                peerPID=(pid_t)message.flags;
                JuiceDisplayAppend(self,[NSString stringWithFormat:
                    @"DISPLAY_EVENT HELLO fd=%d pid=%d desktop=%dx%d dpi=%u\n",
                    fd,peerPID,message.width,message.height,message.stride]);
                dispatch_async(dispatch_get_main_queue(),^{
                    JuiceDisplaySetValue(self,@"wineDesktopSize",
                        [NSValue valueWithCGSize:CGSizeMake(message.width,message.height)]);
                });
            }
            else if(message.type==JUICE_DISPLAY_WINDOW)
            {
                dispatch_async(dispatch_get_main_queue(),^{
                    SEL selector=NSSelectorFromString(@"updateWindowMessage:client:");
                    if([self respondsToSelector:selector])
                        ((void (*)(id,SEL,JuiceDisplayMsg,int))objc_msgSend)(self,selector,message,fd);
                });
            }
            else if(message.type==JUICE_DISPLAY_DESTROY)
            {
                JuiceInvalidateHWND(self,message.hwnd);
                dispatch_async(dispatch_get_main_queue(),^{
                    SEL selector=NSSelectorFromString(@"destroyWindowHwnd:");
                    if([self respondsToSelector:selector])
                        ((void (*)(id,SEL,uint64_t))objc_msgSend)(self,selector,message.hwnd);
                });
            }
            else if(message.type==JUICE_DISPLAY_FRAME)
            {
                BOOL dirty=(message.flags&JUICE_DISPLAY_DIRTY)!=0;
                JuiceDisplayFramebuffer *frame=dirty?
                    JuiceApplyDirty(self,message,data,fd,peerPID):
                    JuiceApplyFull(self,message,data,fd,peerPID);
                if(frame){JuiceScheduleFrame(self,frame,firstFrame);firstFrame=NO;}
            }
        }
    }

    JuiceDisplayAppend(self,[NSString stringWithFormat:@"DISPLAY_CLIENT_CLOSED fd=%d pid=%d\n",fd,peerPID]);
    JuiceInvalidateClient(self,fd);
    close(fd);
    NSMutableArray *clients=JuiceDisplayValue(self,@"clients");
    if([clients isKindOfClass:NSMutableArray.class])
    {
        @synchronized(clients){[clients removeObject:@(fd)];}
    }
    if([JuiceDisplayValue(self,@"activeClient") intValue]==fd)
        JuiceDisplaySetValue(self,@"activeClient",@(-1));
    dispatch_async(dispatch_get_main_queue(),^{
        SEL selector=NSSelectorFromString(@"removeWindowsForClient:");
        if([self respondsToSelector:selector])
            ((void (*)(id,SEL,int))objc_msgSend)(self,selector,fd);
    });
}

__attribute__((constructor(300)))
static void JuiceInstallDisplayTransportHardening(void)
{
    signal(SIGPIPE,SIG_IGN);
    struct rlimit limit={0};
    if(getrlimit(RLIMIT_NOFILE,&limit)==0&&limit.rlim_cur<limit.rlim_max)
    {
        struct rlimit requested=limit;
        rlim_t target=limit.rlim_max;
        if(target==RLIM_INFINITY||target>1024)target=1024;
        if(requested.rlim_cur<target){requested.rlim_cur=target;setrlimit(RLIMIT_NOFILE,&requested);}
    }
    Class cls=NSClassFromString(@"JuiceController");
    if(!cls)return;
    Method method=class_getInstanceMethod(cls,NSSelectorFromString(@"readClient:"));
    if(method)method_setImplementation(method,(IMP)JuiceHardenedReadClient);
}
