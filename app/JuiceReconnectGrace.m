#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

/* Preserve window geometry/images across brief display-socket reconnects. The
 * Wine transport now reconnects on demand and sends a new full baseline per
 * HWND; deleting WineWindowState immediately would otherwise recreate the
 * recovered image at (0,0) until another WINDOW message arrives. */

static void (*JuiceReconnectOriginalRemoveWindows)(id,SEL,int);
static const NSTimeInterval JuiceReconnectGraceSeconds=3.0;

static id JuiceReconnectValue(id object,NSString *key){@try{return [object valueForKey:key];}@catch(__unused NSException *e){return nil;}}
static void JuiceReconnectSetValue(id object,NSString *key,id value){@try{[object setValue:value forKey:key];}@catch(__unused NSException *e){}}
static void JuiceReconnectAppend(id self,NSString *line){SEL s=NSSelectorFromString(@"append:");if([self respondsToSelector:s])((void(*)(id,SEL,id))objc_msgSend)(self,s,line);}

static NSDictionary *JuiceReconnectSnapshot(id self,int fd)
{
    NSDictionary *windows=JuiceReconnectValue(self,@"wineWindows");if(![windows isKindOfClass:NSDictionary.class])return @{};
    NSMutableDictionary *snapshot=[NSMutableDictionary dictionary];
    [windows enumerateKeysAndObjectsUsingBlock:^(NSNumber *key,id state,BOOL *stop){
        (void)stop;if([JuiceReconnectValue(state,@"clientFD") intValue]!=fd)return;
        snapshot[key]=@{@"state":state,
                        @"image":JuiceReconnectValue(state,@"image")?:NSNull.null,
                        @"frame":JuiceReconnectValue(state,@"frame")?:NSNull.null,
                        @"visible":JuiceReconnectValue(state,@"visible")?:@NO};
    }];
    return snapshot;
}

static BOOL JuiceReconnectUnchanged(id state,NSDictionary *before,int fd)
{
    if(!state||state!=before[@"state"]||[JuiceReconnectValue(state,@"clientFD") intValue]!=fd)return NO;
    id image=JuiceReconnectValue(state,@"image")?:NSNull.null;
    if(image!=before[@"image"])return NO;
    id frame=JuiceReconnectValue(state,@"frame")?:NSNull.null;
    if(![frame isEqual:before[@"frame"]])return NO;
    id visible=JuiceReconnectValue(state,@"visible")?:@NO;
    return [visible isEqual:before[@"visible"]];
}

static void JuiceReconnectRemoveWindows(id self,SEL _cmd,int fd)
{
    NSDictionary *snapshot=JuiceReconnectSnapshot(self,fd);
    if(!snapshot.count)
    {
        if(JuiceReconnectOriginalRemoveWindows)JuiceReconnectOriginalRemoveWindows(self,_cmd,fd);
        return;
    }

    if([JuiceReconnectValue(self,@"inputClient") intValue]==fd)
    {JuiceReconnectSetValue(self,@"inputClient",@(-1));JuiceReconnectSetValue(self,@"inputHwnd",@0);}
    if([JuiceReconnectValue(self,@"activeClient") intValue]==fd)JuiceReconnectSetValue(self,@"activeClient",@(-1));

    JuiceReconnectAppend(self,[NSString stringWithFormat:@"DISPLAY_RECONNECT_GRACE fd=%d windows=%lu seconds=%.1f\n",fd,(unsigned long)snapshot.count,JuiceReconnectGraceSeconds]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(JuiceReconnectGraceSeconds*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        NSMutableDictionary *windows=JuiceReconnectValue(self,@"wineWindows");
        NSMutableArray *order=JuiceReconnectValue(self,@"wineWindowOrder");
        if(![windows isKindOfClass:NSMutableDictionary.class]||![order isKindOfClass:NSMutableArray.class])
        {
            if(JuiceReconnectOriginalRemoveWindows)JuiceReconnectOriginalRemoveWindows(self,_cmd,fd);
            return;
        }
        NSMutableArray<NSNumber *> *remove=[NSMutableArray array];
        [snapshot enumerateKeysAndObjectsUsingBlock:^(NSNumber *key,NSDictionary *before,BOOL *stop){
            (void)stop;if(JuiceReconnectUnchanged(windows[key],before,fd))[remove addObject:key];
        }];
        for(NSNumber *key in remove)[windows removeObjectForKey:key];
        [order removeObjectsInArray:remove];
        if(remove.count&&[JuiceReconnectValue(self,@"experimentalMultiWindow") boolValue])
        {
            SEL composite=NSSelectorFromString(@"compositeWineDesktop");
            if([self respondsToSelector:composite])((void(*)(id,SEL))objc_msgSend)(self,composite);
        }
        JuiceReconnectAppend(self,[NSString stringWithFormat:@"DISPLAY_RECONNECT_GRACE_END fd=%d preserved=%lu removed=%lu\n",fd,(unsigned long)(snapshot.count-remove.count),(unsigned long)remove.count]);
    });
}

__attribute__((constructor(320)))
static void JuiceInstallReconnectGrace(void)
{
    Class cls=NSClassFromString(@"JuiceController");if(!cls)return;
    Method method=class_getInstanceMethod(cls,NSSelectorFromString(@"removeWindowsForClient:"));if(!method)return;
    JuiceReconnectOriginalRemoveWindows=(void(*)(id,SEL,int))method_setImplementation(method,(IMP)JuiceReconnectRemoveWindows);
}
