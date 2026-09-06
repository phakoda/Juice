#import <Foundation/Foundation.h>
#import "JuiceAsyncWriter.h"
#import "JuiceSocketIO.h"
#import <errno.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdint.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>
#import "../wine/dlls/wineios.drv/control_protocol.h"

typedef struct
{
    uint32_t magic,type,size;
    uint64_t hwnd;
    int32_t x,y,width,height;
    uint32_t stride,flags;
} JuiceHostMsg;

static id JuiceHostValue(id object,NSString *key){@try{return [object valueForKey:key];}@catch(__unused NSException *e){return nil;}}
static void JuiceHostSetValue(id object,NSString *key,id value){@try{[object setValue:value forKey:key];}@catch(__unused NSException *e){}}
static void JuiceHostAppend(id self,NSString *line){SEL s=NSSelectorFromString(@"append:");if([self respondsToSelector:s])((void(*)(id,SEL,id))objc_msgSend)(self,s,line);}
static char JuiceHostWritersKey;

/* Registry access and send membership share one lock. A writer owns a duplicate
 * of this connection, so queued work can never target a recycled numeric fd. */
static NSMutableDictionary *JuiceHostWriters(NSMutableArray *clients)
{
    NSMutableDictionary *writers=objc_getAssociatedObject(clients,&JuiceHostWritersKey);
    if(!writers)
    {
        writers=[NSMutableDictionary dictionary];
        objc_setAssociatedObject(clients,&JuiceHostWritersKey,writers,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return writers;
}

void JuiceCancelDisplayWriter(id self,int fd)
{
    NSMutableArray *clients=JuiceHostValue(self,@"clients");
    if(![clients isKindOfClass:NSMutableArray.class])return;
    @synchronized(clients)
    {
        NSMutableDictionary *writers=JuiceHostWriters(clients);
        [writers[@(fd)] cancel];
        [writers removeObjectForKey:@(fd)];
    }
}

static BOOL JuiceHostEnqueue(id self,int fd,NSData *packet)
{
    NSMutableArray *clients=JuiceHostValue(self,@"clients");
    if(![clients isKindOfClass:NSMutableArray.class])return NO;
    @synchronized(clients)
    {
        if(![clients containsObject:@(fd)])return NO;
        NSMutableDictionary *writers=JuiceHostWriters(clients);
        JuiceAsyncWriter *writer=writers[@(fd)];
        if(!writer)
        {
            __weak id weakSelf=self;
            writer=[[JuiceAsyncWriter alloc]initWithFD:fd socket:YES limit:2u*1024u*1024u failure:^(int error){
                id target=weakSelf;
                if(target)JuiceHostAppend(target,[NSString stringWithFormat:
                    @"HOST_IO_WRITE_FAILED channel=display fd=%d errno=%d connection_shutdown=1\n",fd,error]);
            }];
            if(writer)writers[@(fd)]=writer;
        }
        if(writer&&[writer enqueueData:packet])return YES;
        int saved=errno;
        /* Never silently lose key/button-up events when the queue is full.
         * Disconnect instead, so reconnect resets the input route/state. */
        shutdown(fd,SHUT_RDWR);
        [writer cancel];
        [writers removeObjectForKey:@(fd)];
        JuiceHostAppend(self,[NSString stringWithFormat:
            @"HOST_IO_QUEUE_REJECTED fd=%d errno=%d connection_shutdown=1\n",fd,saved]);
        return NO;
    }
}
static void JuiceControlCopy(char *destination,size_t capacity,NSString *value)
{
    if(!capacity)return;destination[0]=0;if(value.length)[value getCString:destination maxLength:capacity encoding:NSUTF8StringEncoding];destination[capacity-1]=0;
}
static BOOL JuiceSendMessage(id self,SEL _cmd,JuiceHostMsg *message,NSData *payload,int fd)
{
    (void)_cmd;
    if(!message||fd<0||payload.length>64u*1024u)return NO;
    JuiceHostMsg header=*message;header.size=(uint32_t)payload.length;
    NSMutableData *packet=[NSMutableData dataWithBytes:&header length:sizeof(header)];
    if(payload.length)[packet appendData:payload];
    return JuiceHostEnqueue(self,fd,packet);
}
static void JuiceBroadcast(id self,SEL _cmd,const void *buffer,size_t length)
{
    (void)_cmd;int fd=[JuiceHostValue(self,@"activeClient") intValue];
    if(fd<0||!buffer||!length||length>sizeof(JuiceHostMsg)+64u*1024u)return;
    JuiceHostEnqueue(self,fd,[NSData dataWithBytes:buffer length:length]);
}
static void JuiceControlResponse(id self,SEL _cmd,int fd,uint32_t request,int32_t status,NSString *path,NSString *detail)
{
    (void)_cmd;struct juice_control_message message={0};message.magic=JUICE_CONTROL_MAGIC;message.version=JUICE_CONTROL_VERSION;
    message.type=JUICE_CONTROL_IMPORT_RESPONSE;message.size=sizeof(message);message.request_id=request;message.status=status;
    JuiceControlCopy(message.path,sizeof(message.path),path);JuiceControlCopy(message.detail,sizeof(message.detail),detail);
    NSData *wire=[NSData dataWithBytes:&message length:sizeof(message)];
    __weak id weakSelf=self;
    JuiceAsyncWriter *writer=[[JuiceAsyncWriter alloc]initWithFD:fd socket:YES limit:sizeof(message) failure:^(int error){
        id target=weakSelf;
        if(target)JuiceHostAppend(target,[NSString stringWithFormat:@"HOST_IO_WRITE_FAILED channel=control request=%u errno=%d\n",request,error]);
    }];
    int setupError=writer?0:errno;
    close(fd); /* The queued writer owns the only remaining host reference. */
    if(!writer||![writer enqueueData:wire])
        JuiceHostAppend(self,[NSString stringWithFormat:@"HOST_IO_QUEUE_REJECTED channel=control request=%u errno=%d\n",request,setupError?:errno]);
}
static void JuiceReply(id self,int fd,uint32_t request,int32_t status,NSString *path,NSString *detail)
{
    SEL s=NSSelectorFromString(@"sendControlResponseToFD:request:status:path:detail:");
    if([self respondsToSelector:s])((void(*)(id,SEL,int,uint32_t,int32_t,id,id))objc_msgSend)(self,s,fd,request,status,path?:@"",detail?:@"");else close(fd);
}
static void JuiceReadControl(id self,SEL _cmd,int fd)
{
    (void)_cmd;struct juice_control_message message;
    if(!JuiceSocketTransferUntil(fd,&message,sizeof(message),0,JuiceSocketNowMS()+5000)||message.magic!=JUICE_CONTROL_MAGIC||message.version!=JUICE_CONTROL_VERSION||message.size!=sizeof(message))
    {JuiceHostAppend(self,[NSString stringWithFormat:@"CONTROL_V1_PROTOCOL_REJECTED fd=%d\n",fd]);close(fd);return;}
    if(message.type==JUICE_CONTROL_IMPORT_REQUEST)
    {
        BOOL busy=NO;@synchronized(self)
        {
            if([JuiceHostValue(self,@"controlPickerFD") intValue]>=0)busy=YES;
            else{JuiceHostSetValue(self,@"controlPickerFD",@(fd));JuiceHostSetValue(self,@"controlRequestID",@(message.request_id));JuiceHostSetValue(self,@"controlFilters",@(message.flags));}
        }
        if(busy){JuiceReply(self,fd,message.request_id,JUICE_CONTROL_STATUS_ERROR,@"",@"Another Juice import request is already active.");return;}
        dispatch_async(dispatch_get_main_queue(),^{SEL s=NSSelectorFromString(@"presentControlPicker");if([self respondsToSelector:s])((void(*)(id,SEL))objc_msgSend)(self,s);else
        {
            @synchronized(self)
            {
                if([JuiceHostValue(self,@"controlPickerFD") intValue]==fd)
                {
                    JuiceHostSetValue(self,@"controlPickerFD",@(-1));
                    JuiceHostSetValue(self,@"controlRequestID",@0);
                    JuiceHostSetValue(self,@"controlFilters",@0);
                }
            }
            JuiceReply(self,fd,message.request_id,JUICE_CONTROL_STATUS_ERROR,@"",@"The host file picker is unavailable.");
        }});
        return;
    }
    if(message.type==JUICE_CONTROL_HOST_ACTION)
    {
        size_t pathLength=strnlen(message.path,sizeof(message.path));
        if(pathLength==sizeof(message.path)){close(fd);return;}
        NSString *path=[[NSString alloc]initWithBytes:message.path length:pathLength encoding:NSUTF8StringEncoding];
        if(!path){close(fd);return;}
        uint32_t action=message.flags;close(fd);dispatch_async(dispatch_get_main_queue(),^{SEL s=NSSelectorFromString(@"handleControlAction:path:");if([self respondsToSelector:s])((void(*)(id,SEL,uint32_t,id))objc_msgSend)(self,s,action,path);});return;
    }
    close(fd);
}

__attribute__((constructor(220)))
static void JuiceInstallHostIO(void)
{
    Class cls=NSClassFromString(@"JuiceController");if(!cls)return;
    Method send=class_getInstanceMethod(cls,NSSelectorFromString(@"sendMessage:payload:toFD:"));if(send)method_setImplementation(send,(IMP)JuiceSendMessage);
    Method broadcast=class_getInstanceMethod(cls,NSSelectorFromString(@"broadcast:size:"));if(broadcast)method_setImplementation(broadcast,(IMP)JuiceBroadcast);
    Method response=class_getInstanceMethod(cls,NSSelectorFromString(@"sendControlResponseToFD:request:status:path:detail:"));if(response)method_setImplementation(response,(IMP)JuiceControlResponse);
    Method control=class_getInstanceMethod(cls,NSSelectorFromString(@"readControlClient:"));if(control)method_setImplementation(control,(IMP)JuiceReadControl);
}
