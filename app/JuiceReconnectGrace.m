#import <UIKit/UIKit.h>
#import <errno.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <signal.h>
#import <unistd.h>

/* Preserve window geometry/images across brief display-socket reconnects. The
 * Wine transport reconnects on demand and sends a new full baseline per HWND;
 * deleting WineWindowState immediately would otherwise recreate the recovered
 * image at (0,0) until another WINDOW message arrives.
 *
 * A host fd number is not a connection identity: accept() may reuse the same
 * integer for a replacement connection. Retained states therefore have their
 * clientFD invalidated immediately and are tagged with the Wine peer PID seen
 * on frame presentation. Input routing cannot reuse the dead descriptor; a real
 * reconnect explicitly reclaims the state by assigning its current fd. The
 * geometry grace is extended only while the original Wine process is alive. */

typedef struct
{
    uint32_t magic,type,size;
    uint64_t hwnd;
    int32_t x,y,width,height;
    uint32_t stride,flags;
} JuiceReconnectMsg;

static void (*JuiceReconnectOriginalRemoveWindows)(id,SEL,int);
static void (*JuiceReconnectOriginalPresentFrame)(id,SEL,JuiceReconnectMsg,NSData *,int,pid_t,BOOL);
static const NSTimeInterval JuiceReconnectGraceSeconds=3.0;
static char JuiceReconnectPeerPIDKey;

static id JuiceReconnectValue(id object,NSString *key){@try{return [object valueForKey:key];}@catch(__unused NSException *e){return nil;}}
static void JuiceReconnectSetValue(id object,NSString *key,id value){@try{[object setValue:value forKey:key];}@catch(__unused NSException *e){}}
static void JuiceReconnectAppend(id self,NSString *line){SEL s=NSSelectorFromString(@"append:");if([self respondsToSelector:s])((void(*)(id,SEL,id))objc_msgSend)(self,s,line);}

static pid_t JuiceReconnectStatePeerPID(id state)
{
    return (pid_t)[objc_getAssociatedObject(state,&JuiceReconnectPeerPIDKey) intValue];
}

static BOOL JuiceReconnectPeerAlive(pid_t peerPID)
{
    if(peerPID<=0)return NO;
    errno=0;
    return kill(peerPID,0)==0||errno==EPERM;
}

static void JuiceReconnectPresentFrame(id self,SEL _cmd,JuiceReconnectMsg message,
                                       NSData *data,int fd,pid_t peerPID,BOOL first)
{
    if(JuiceReconnectOriginalPresentFrame)
        JuiceReconnectOriginalPresentFrame(self,_cmd,message,data,fd,peerPID,first);
    if(peerPID<=0||!message.hwnd)return;
    NSDictionary *windows=JuiceReconnectValue(self,@"wineWindows");
    id state=[windows isKindOfClass:NSDictionary.class]?windows[@(message.hwnd)]:nil;
    if(state)objc_setAssociatedObject(state,&JuiceReconnectPeerPIDKey,@(peerPID),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSDictionary *JuiceReconnectSnapshot(id self,int fd)
{
    NSDictionary *windows=JuiceReconnectValue(self,@"wineWindows");if(![windows isKindOfClass:NSDictionary.class])return @{};
    NSMutableDictionary *snapshot=[NSMutableDictionary dictionary];
    [windows enumerateKeysAndObjectsUsingBlock:^(NSNumber *key,id state,BOOL *stop){
        (void)stop;if([JuiceReconnectValue(state,@"clientFD") intValue]!=fd)return;
        snapshot[key]=@{@"state":state,
                        @"image":JuiceReconnectValue(state,@"image")?:NSNull.null,
                        @"frame":JuiceReconnectValue(state,@"frame")?:NSNull.null,
                        @"visible":JuiceReconnectValue(state,@"visible")?:@NO,
                        @"peerPID":@(JuiceReconnectStatePeerPID(state))};
    }];
    return snapshot;
}

/* A retained state is unchanged only while it is still disconnected. Any
 * WINDOW or FRAME from a real reconnect sets clientFD back to a live value and
 * makes the old grace snapshot ineligible for pruning, even if the new socket
 * happens to reuse the exact same numeric fd. */
static BOOL JuiceReconnectUnchanged(id state,NSDictionary *before,int fd)
{
    (void)fd;
    if(!state||state!=before[@"state"]||[JuiceReconnectValue(state,@"clientFD") intValue]!=-1)return NO;
    id image=JuiceReconnectValue(state,@"image")?:NSNull.null;
    if(image!=before[@"image"])return NO;
    id frame=JuiceReconnectValue(state,@"frame")?:NSNull.null;
    if(![frame isEqual:before[@"frame"]])return NO;
    id visible=JuiceReconnectValue(state,@"visible")?:@NO;
    return [visible isEqual:before[@"visible"]];
}

static void JuiceReconnectSchedulePrune(id self,SEL _cmd,int fd,NSDictionary *snapshot,NSUInteger attempt)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(JuiceReconnectGraceSeconds*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        NSMutableDictionary *windows=JuiceReconnectValue(self,@"wineWindows");
        NSMutableArray *order=JuiceReconnectValue(self,@"wineWindowOrder");
        if(![windows isKindOfClass:NSMutableDictionary.class]||![order isKindOfClass:NSMutableArray.class])
        {
            if(JuiceReconnectOriginalRemoveWindows)JuiceReconnectOriginalRemoveWindows(self,_cmd,fd);
            return;
        }

        NSMutableArray<NSNumber *> *remove=[NSMutableArray array];
        __block NSUInteger livePeers=0;
        [snapshot enumerateKeysAndObjectsUsingBlock:^(NSNumber *key,NSDictionary *before,BOOL *stop){
            (void)stop;
            id state=windows[key];
            if(!JuiceReconnectUnchanged(state,before,fd))return;
            pid_t peerPID=(pid_t)[before[@"peerPID"] intValue];
            if(JuiceReconnectPeerAlive(peerPID)){livePeers++;return;}
            [remove addObject:key];
        }];

        for(NSNumber *key in remove)[windows removeObjectForKey:key];
        [order removeObjectsInArray:remove];
        if(remove.count&&[JuiceReconnectValue(self,@"experimentalMultiWindow") boolValue])
        {
            SEL composite=NSSelectorFromString(@"compositeWineDesktop");
            if([self respondsToSelector:composite])((void(*)(id,SEL))objc_msgSend)(self,composite);
        }

        NSUInteger preserved=snapshot.count-remove.count;
        if(livePeers)
        {
            if(attempt==1||attempt%10==0)
                JuiceReconnectAppend(self,[NSString stringWithFormat:
                    @"DISPLAY_RECONNECT_GRACE_EXTEND fd=%d live_windows=%lu attempt=%lu\n",
                    fd,(unsigned long)livePeers,(unsigned long)attempt]);
            JuiceReconnectSchedulePrune(self,_cmd,fd,snapshot,attempt+1);
            return;
        }
        JuiceReconnectAppend(self,[NSString stringWithFormat:
            @"DISPLAY_RECONNECT_GRACE_END fd=%d preserved=%lu removed=%lu attempts=%lu\n",
            fd,(unsigned long)preserved,(unsigned long)remove.count,(unsigned long)attempt]);
    });
}

static void JuiceReconnectRemoveWindows(id self,SEL _cmd,int fd)
{
    NSDictionary *snapshot=JuiceReconnectSnapshot(self,fd);
    if(!snapshot.count)
    {
        if(JuiceReconnectOriginalRemoveWindows)JuiceReconnectOriginalRemoveWindows(self,_cmd,fd);
        return;
    }

    /* Geometry/image state may survive; transport ownership may not. Clear the
     * dead fd on every retained state before another accept() can reuse it. */
    [snapshot enumerateKeysAndObjectsUsingBlock:^(NSNumber *key,NSDictionary *before,BOOL *stop){
        (void)key;(void)stop;
        id state=before[@"state"];
        if([JuiceReconnectValue(state,@"clientFD") intValue]==fd)
            JuiceReconnectSetValue(state,@"clientFD",@(-1));
    }];
    if([JuiceReconnectValue(self,@"inputClient") intValue]==fd)
    {JuiceReconnectSetValue(self,@"inputClient",@(-1));JuiceReconnectSetValue(self,@"inputHwnd",@0);}
    if([JuiceReconnectValue(self,@"activeClient") intValue]==fd)JuiceReconnectSetValue(self,@"activeClient",@(-1));

    JuiceReconnectAppend(self,[NSString stringWithFormat:
        @"DISPLAY_RECONNECT_GRACE fd=%d windows=%lu seconds=%.1f peer_liveness=1 state_fds_cleared=1\n",
        fd,(unsigned long)snapshot.count,JuiceReconnectGraceSeconds]);
    JuiceReconnectSchedulePrune(self,_cmd,fd,snapshot,1);
}

__attribute__((constructor(320)))
static void JuiceInstallReconnectGrace(void)
{
    Class cls=NSClassFromString(@"JuiceController");if(!cls)return;
    Method remove=class_getInstanceMethod(cls,NSSelectorFromString(@"removeWindowsForClient:"));
    if(remove)JuiceReconnectOriginalRemoveWindows=(void(*)(id,SEL,int))method_setImplementation(remove,(IMP)JuiceReconnectRemoveWindows);
    Method present=class_getInstanceMethod(cls,NSSelectorFromString(@"presentFrameMessage:data:client:peerPID:first:"));
    if(present)JuiceReconnectOriginalPresentFrame=(void(*)(id,SEL,JuiceReconnectMsg,NSData *,int,pid_t,BOOL))method_setImplementation(present,(IMP)JuiceReconnectPresentFrame);
}
