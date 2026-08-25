#import <Foundation/Foundation.h>
#import <errno.h>
#import <fcntl.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

static char JuiceDisplayListenerGenerationKey;
static char JuiceControlListenerGenerationKey;

static id JuiceSocketValue(id object, NSString *key)
{
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}
static void JuiceSocketSetValue(id object, NSString *key, id value)
{
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}
static void JuiceSocketAppend(id self, NSString *line)
{
    SEL selector=NSSelectorFromString(@"append:");
    if([self respondsToSelector:selector])((void (*)(id,SEL,id))objc_msgSend)(self,selector,line);
}
static NSString *JuiceSocketRoot(void)
{
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"JuiceSockets"];
}
static const void *JuiceListenerGenerationKey(BOOL control)
{
    return control ? &JuiceControlListenerGenerationKey : &JuiceDisplayListenerGenerationKey;
}
static NSUInteger JuiceListenerGeneration(id self,BOOL control)
{
    return [objc_getAssociatedObject(self,JuiceListenerGenerationKey(control)) unsignedIntegerValue];
}
static NSUInteger JuiceBumpListenerGeneration(id self,BOOL control)
{
    NSUInteger generation=JuiceListenerGeneration(self,control)+1;
    if(!generation)generation=1;
    objc_setAssociatedObject(self,JuiceListenerGenerationKey(control),@(generation),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return generation;
}
static BOOL JuiceListenerFDMatchesPath(int fd,NSString *path)
{
    if(fd<0||!path.length)return NO;
    int accepting=0;socklen_t acceptingLength=sizeof(accepting);
    if(getsockopt(fd,SOL_SOCKET,SO_ACCEPTCONN,&accepting,&acceptingLength)||!accepting)return NO;
    struct sockaddr_un address={0};socklen_t addressLength=sizeof(address);
    if(getsockname(fd,(struct sockaddr *)&address,&addressLength)||address.sun_family!=AF_UNIX)return NO;
    const char *wire=path.fileSystemRepresentation;
    return wire&&address.sun_path[0]&&strcmp(address.sun_path,wire)==0;
}
static BOOL JuiceListenerStillCurrent(id self,BOOL control,int listener,NSUInteger generation)
{
    NSString *fdKey=control?@"controlListenFD":@"listenFD";
    NSString *pathKey=control?@"controlSocketPath":@"socketPath";
    NSString *path=JuiceSocketValue(self,pathKey);
    return [JuiceSocketValue(self,fdKey) intValue]==listener&&
           JuiceListenerGeneration(self,control)==generation&&
           JuiceListenerFDMatchesPath(listener,path);
}
static void JuiceSetSocketFlags(int fd)
{
    if(fd<0)return;
    int flags=fcntl(fd,F_GETFD);
    if(flags>=0)fcntl(fd,F_SETFD,flags|FD_CLOEXEC);
#ifdef SO_NOSIGPIPE
    int one=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
#endif
}
static BOOL JuiceBindListener(NSString *path,int backlog,int *fdOut,int *errorOut)
{
    if(fdOut)*fdOut=-1;if(errorOut)*errorOut=0;
    const char *wire=path.fileSystemRepresentation;
    if(!wire||strlen(wire)>=sizeof(((struct sockaddr_un *)0)->sun_path))
    {if(errorOut)*errorOut=ENAMETOOLONG;return NO;}
    unlink(wire);
    int fd=socket(AF_UNIX,SOCK_STREAM,0);
    if(fd<0){if(errorOut)*errorOut=errno;return NO;}
    JuiceSetSocketFlags(fd);
    struct sockaddr_un address={0};address.sun_family=AF_UNIX;
    strncpy(address.sun_path,wire,sizeof(address.sun_path)-1);
    if(bind(fd,(struct sockaddr *)&address,sizeof(address))||listen(fd,backlog))
    {
        int saved=errno;close(fd);unlink(wire);if(errorOut)*errorOut=saved;return NO;
    }
    if(fdOut)*fdOut=fd;return YES;
}
static BOOL JuiceTransientAccept(int error)
{
    switch(error)
    {
        case EINTR:case ECONNABORTED:case EMFILE:case ENFILE:case ENOBUFS:case ENOMEM:
#if EAGAIN != EWOULDBLOCK
        case EAGAIN:
#endif
        case EWOULDBLOCK:return YES;
        default:return NO;
    }
}
static BOOL JuiceTransientListenerSetup(int error)
{
    switch(error)
    {
        case EMFILE:case ENFILE:case ENOBUFS:case ENOMEM:case EAGAIN:
#if EAGAIN != EWOULDBLOCK
        case EWOULDBLOCK:
#endif
            return YES;
        default:return NO;
    }
}
static useconds_t JuiceAcceptBackoff(unsigned failures,int error)
{
    if(error==EINTR)return 0;
    unsigned exponent=failures>6?6:failures;
    useconds_t delay=(useconds_t)20000u<<exponent;
    if(error==EMFILE||error==ENFILE||error==ENOMEM)delay=MAX(delay,(useconds_t)100000u);
    return MIN(delay,(useconds_t)1000000u);
}
static void JuiceListenerEnded(id self,BOOL control,int listener,NSUInteger generation,int error)
{
    NSString *fdKey=control?@"controlListenFD":@"listenFD";
    NSString *pathKey=control?@"controlSocketPath":@"socketPath";
    if([JuiceSocketValue(self,fdKey) intValue]!=listener||
       JuiceListenerGeneration(self,control)!=generation)return;
    NSString *path=JuiceSocketValue(self,pathKey);
    BOOL owned=JuiceListenerFDMatchesPath(listener,path);
    if(owned)close(listener);
    JuiceSocketSetValue(self,fdKey,@(-1));
    if(path.length)unlink(path.fileSystemRepresentation);
    JuiceSocketAppend(self,[NSString stringWithFormat:
        @"SOCKET_LISTENER_ENDED kind=%@ fd=%d generation=%lu errno=%d owned=%d restartable=1\n",
        control?@"control":@"display",listener,(unsigned long)generation,error,owned]);
}
static void JuiceAcceptLoop(id self,int listener,BOOL control,NSUInteger generation)
{
    unsigned failures=0;int finalError=0;
    for(;;)
    {
        if(!JuiceListenerStillCurrent(self,control,listener,generation))return;
        int fd=accept(listener,NULL,NULL);
        if(fd<0)
        {
            int saved=errno;
            if(!JuiceListenerStillCurrent(self,control,listener,generation))return;
            if(saved==EINTR)continue;
            if(JuiceTransientAccept(saved))
            {
                failures++;
                if(failures==1||(failures&(failures-1))==0)
                    JuiceSocketAppend(self,[NSString stringWithFormat:
                        @"SOCKET_ACCEPT_RETRY kind=%@ fd=%d generation=%lu errno=%d failures=%u persistent=1\n",
                        control?@"control":@"display",listener,(unsigned long)generation,saved,failures]);
                useconds_t delay=JuiceAcceptBackoff(failures,saved);
                if(delay)usleep(delay);
                continue;
            }
            finalError=saved;break;
        }
        if(!JuiceListenerStillCurrent(self,control,listener,generation))
        {
            close(fd);
            return;
        }
        failures=0;JuiceSetSocketFlags(fd);
        if(!control)
        {
            NSMutableArray *clients=JuiceSocketValue(self,@"clients");
            if([clients isKindOfClass:NSMutableArray.class])@synchronized(clients){[clients addObject:@(fd)];}
            JuiceSocketAppend(self,[NSString stringWithFormat:
                @"DISPLAY_CLIENT_CONNECTED fd=%d listener_generation=%lu cloexec=1\n",
                fd,(unsigned long)generation]);
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            SEL selector=NSSelectorFromString(control?@"readControlClient:":@"readClient:");
            if([self respondsToSelector:selector])((void (*)(id,SEL,int))objc_msgSend)(self,selector,fd);
            else close(fd);
        });
    }
    JuiceListenerEnded(self,control,listener,generation,finalError);
}
static void JuiceStartListener(id self,BOOL control);
static void JuiceScheduleListenerRestart(id self,BOOL control,NSUInteger generation,int error)
{
    if(!JuiceTransientListenerSetup(error))return;
    JuiceSocketAppend(self,[NSString stringWithFormat:
        @"SOCKET_BIND_RETRY kind=%@ generation=%lu errno=%d delay_ms=500\n",
        control?@"control":@"display",(unsigned long)generation,error]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(500*NSEC_PER_MSEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSString *fdKey=control?@"controlListenFD":@"listenFD";
        if(JuiceListenerGeneration(self,control)!=generation||
           [JuiceSocketValue(self,fdKey) intValue]>=0)return;
        JuiceStartListener(self,control);
    });
}
static void JuiceStartListener(id self,BOOL control)
{
    NSString *fdKey=control?@"controlListenFD":@"listenFD";
    NSString *pathKey=control?@"controlSocketPath":@"socketPath";
    int old=[JuiceSocketValue(self,fdKey) intValue];
    NSString *oldPath=JuiceSocketValue(self,pathKey);
    BOOL oldIsListener=JuiceListenerFDMatchesPath(old,oldPath);
    BOOL pathPresent=oldPath.length&&access(oldPath.fileSystemRepresentation,F_OK)==0;
    if(oldIsListener&&pathPresent)
    {
        JuiceSocketAppend(self,[NSString stringWithFormat:
            @"SOCKET_LISTENER_ALREADY_RUNNING kind=%@ fd=%d generation=%lu\n",
            control?@"control":@"display",old,(unsigned long)JuiceListenerGeneration(self,control)]);
        return;
    }
    if(oldIsListener)close(old);
    if(old>=0)JuiceSocketSetValue(self,fdKey,@(-1));
    if(oldPath.length)unlink(oldPath.fileSystemRepresentation);

    NSUInteger generation=JuiceBumpListenerGeneration(self,control);
    NSString *root=JuiceSocketRoot();NSError *error=nil;
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:&error];
    NSString *path=[root stringByAppendingPathComponent:control?@"control.sock":@"display.sock"];
    JuiceSocketSetValue(self,pathKey,path);
    int listener=-1,saved=error?EACCES:0;
    BOOL ready=!error&&JuiceBindListener(path,control?4:8,&listener,&saved);
    JuiceSocketSetValue(self,fdKey,@(listener));
    JuiceSocketAppend(self,[NSString stringWithFormat:
        @"%@ path=%@ ready=%d fd=%d generation=%lu errno=%d temp_socket=1 cloexec=1\n",
        control?@"CONTROL_V1_SOCKET":@"DISPLAY_SOCKET",path,ready,listener,
        (unsigned long)generation,saved]);
    if(ready)
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            JuiceAcceptLoop(self,listener,control,generation);
        });
    else JuiceScheduleListenerRestart(self,control,generation,saved);
}
static void JuiceStartDisplay(id self,SEL _cmd){(void)_cmd;JuiceStartListener(self,NO);}
static void JuiceStartControl(id self,SEL _cmd){(void)_cmd;JuiceStartListener(self,YES);}

__attribute__((constructor(200)))
static void JuiceInstallSocketHardening(void)
{
    Class cls=NSClassFromString(@"JuiceController");if(!cls)return;
    Method display=class_getInstanceMethod(cls,NSSelectorFromString(@"startDisplayServer"));
    Method control=class_getInstanceMethod(cls,NSSelectorFromString(@"startControlServer"));
    if(display)method_setImplementation(display,(IMP)JuiceStartDisplay);
    if(control)method_setImplementation(control,(IMP)JuiceStartControl);
}
