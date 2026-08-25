#import <Foundation/Foundation.h>
#import <errno.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdint.h>
#import <string.h>
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
static BOOL JuiceReadExact(int fd,void *buffer,size_t length)
{
    uint8_t *p=buffer;while(length){ssize_t n=read(fd,p,length);if(n<0&&errno==EINTR)continue;if(n<=0)return NO;p+=n;length-=(size_t)n;}return YES;
}
static BOOL JuiceWriteExact(int fd,const void *buffer,size_t length)
{
    const uint8_t *p=buffer;while(length){ssize_t n=write(fd,p,length);if(n<0&&errno==EINTR)continue;if(n<=0)return NO;p+=n;length-=(size_t)n;}return YES;
}
static void JuiceControlCopy(char *destination,size_t capacity,NSString *value)
{
    if(!capacity)return;destination[0]=0;if(value.length)[value getCString:destination maxLength:capacity encoding:NSUTF8StringEncoding];destination[capacity-1]=0;
}
static BOOL JuiceSendMessage(id self,SEL _cmd,JuiceHostMsg *message,NSData *payload,int fd)
{
    (void)_cmd;if(!message||fd<0||payload.length>UINT32_MAX)return NO;message->size=(uint32_t)payload.length;
    NSMutableArray *clients=JuiceHostValue(self,@"clients");if(![clients isKindOfClass:NSMutableArray.class])return NO;
    @synchronized(clients)
    {
        if(![clients containsObject:@(fd)]||!JuiceWriteExact(fd,message,sizeof(*message)))return NO;
        if(payload.length&&!JuiceWriteExact(fd,payload.bytes,payload.length))return NO;
    }
    return YES;
}
static void JuiceBroadcast(id self,SEL _cmd,const void *buffer,size_t length)
{
    (void)_cmd;int fd=[JuiceHostValue(self,@"activeClient") intValue];if(fd<0||!buffer||!length)return;
    NSMutableArray *clients=JuiceHostValue(self,@"clients");if(![clients isKindOfClass:NSMutableArray.class])return;
    @synchronized(clients)
    {
        if([clients containsObject:@(fd)]&&!JuiceWriteExact(fd,buffer,length))
            JuiceHostAppend(self,[NSString stringWithFormat:@"HOST_IO_WRITE_FAILED channel=display fd=%d errno=%d\n",fd,errno]);
    }
}
static void JuiceControlResponse(id self,SEL _cmd,int fd,uint32_t request,int32_t status,NSString *path,NSString *detail)
{
    (void)_cmd;struct juice_control_message message={0};message.magic=JUICE_CONTROL_MAGIC;message.version=JUICE_CONTROL_VERSION;
    message.type=JUICE_CONTROL_IMPORT_RESPONSE;message.size=sizeof(message);message.request_id=request;message.status=status;
    JuiceControlCopy(message.path,sizeof(message.path),path);JuiceControlCopy(message.detail,sizeof(message.detail),detail);
    NSData *wire=[NSData dataWithBytes:&message length:sizeof(message)];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{BOOL ok=JuiceWriteExact(fd,wire.bytes,wire.length);int saved=ok?0:errno;close(fd);if(!ok)JuiceHostAppend(self,[NSString stringWithFormat:@"HOST_IO_WRITE_FAILED channel=control request=%u errno=%d\n",request,saved]);});
}
static void JuiceReply(id self,int fd,uint32_t request,int32_t status,NSString *path,NSString *detail)
{
    SEL s=NSSelectorFromString(@"sendControlResponseToFD:request:status:path:detail:");
    if([self respondsToSelector:s])((void(*)(id,SEL,int,uint32_t,int32_t,id,id))objc_msgSend)(self,s,fd,request,status,path?:@"",detail?:@"");else close(fd);
}
static void JuiceReadControl(id self,SEL _cmd,int fd)
{
    (void)_cmd;struct juice_control_message message;
    if(!JuiceReadExact(fd,&message,sizeof(message))||message.magic!=JUICE_CONTROL_MAGIC||message.version!=JUICE_CONTROL_VERSION||message.size!=sizeof(message))
    {JuiceHostAppend(self,[NSString stringWithFormat:@"CONTROL_V1_PROTOCOL_REJECTED fd=%d\n",fd]);close(fd);return;}
    if(message.type==JUICE_CONTROL_IMPORT_REQUEST)
    {
        BOOL busy=NO;@synchronized(self)
        {
            if([JuiceHostValue(self,@"controlPickerFD") intValue]>=0)busy=YES;
            else{JuiceHostSetValue(self,@"controlPickerFD",@(fd));JuiceHostSetValue(self,@"controlRequestID",@(message.request_id));JuiceHostSetValue(self,@"controlFilters",@(message.flags));}
        }
        if(busy){JuiceReply(self,fd,message.request_id,JUICE_CONTROL_STATUS_ERROR,@"",@"Another Juice import request is already active.");return;}
        dispatch_async(dispatch_get_main_queue(),^{SEL s=NSSelectorFromString(@"presentControlPicker");if([self respondsToSelector:s])((void(*)(id,SEL))objc_msgSend)(self,s);else JuiceReply(self,fd,message.request_id,JUICE_CONTROL_STATUS_ERROR,@"",@"The host file picker is unavailable.");});
        return;
    }
    if(message.type==JUICE_CONTROL_HOST_ACTION)
    {
        NSString *path=[[NSString alloc]initWithBytes:message.path length:strnlen(message.path,sizeof(message.path)) encoding:NSUTF8StringEncoding]?:@"";
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
