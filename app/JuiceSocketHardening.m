#import <Foundation/Foundation.h>
#import <errno.h>
#import <fcntl.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

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
static void JuiceListenerEnded(id self,NSString *fdKey,NSString *pathKey,int listener,NSString *kind,int error)
{
    if([JuiceSocketValue(self,fdKey) intValue]!=listener)return;
    close(listener);JuiceSocketSetValue(self,fdKey,@(-1));
    NSString *path=JuiceSocketValue(self,pathKey);if(path.length)unlink(path.fileSystemRepresentation);
    JuiceSocketAppend(self,[NSString stringWithFormat:
        @"SOCKET_LISTENER_ENDED kind=%@ fd=%d errno=%d restartable=1\n",kind,listener,error]);
}
static void JuiceAcceptLoop(id self,int listener,BOOL control)
{
    unsigned failures=0;int finalError=0;
    for(;;)
    {
        int fd=accept(listener,NULL,NULL);
        if(fd<0)
        {
            int saved=errno;if(saved==EINTR)continue;
            if(JuiceTransientAccept(saved)&&failures++<20)
            {
                if(failures==1)JuiceSocketAppend(self,[NSString stringWithFormat:
                    @"SOCKET_ACCEPT_RETRY kind=%@ errno=%d\n",control?@"control":@"display",saved]);
                usleep(saved==EMFILE||saved==ENFILE?100000:20000);continue;
            }
            finalError=saved;break;
        }
        failures=0;JuiceSetSocketFlags(fd);
        if(!control)
        {
            NSMutableArray *clients=JuiceSocketValue(self,@"clients");
            if([clients isKindOfClass:NSMutableArray.class])@synchronized(clients){[clients addObject:@(fd)];}
            JuiceSocketAppend(self,[NSString stringWithFormat:@"DISPLAY_CLIENT_CONNECTED fd=%d cloexec=1\n",fd]);
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            SEL selector=NSSelectorFromString(control?@"readControlClient:":@"readClient:");
            if([self respondsToSelector:selector])((void (*)(id,SEL,int))objc_msgSend)(self,selector,fd);
            else close(fd);
        });
    }
    JuiceListenerEnded(self,control?@"controlListenFD":@"listenFD",
                       control?@"controlSocketPath":@"socketPath",listener,
                       control?@"control":@"display",finalError);
}
static void JuiceStartListener(id self,BOOL control)
{
    NSString *root=JuiceSocketRoot();NSError *error=nil;
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:&error];
    NSString *path=[root stringByAppendingPathComponent:control?@"control.sock":@"display.sock"];
    NSString *fdKey=control?@"controlListenFD":@"listenFD";
    NSString *pathKey=control?@"controlSocketPath":@"socketPath";
    JuiceSocketSetValue(self,pathKey,path);
    int listener=-1,saved=error?EACCES:0;
    BOOL ready=!error&&JuiceBindListener(path,control?4:8,&listener,&saved);
    JuiceSocketSetValue(self,fdKey,@(listener));
    JuiceSocketAppend(self,[NSString stringWithFormat:
        @"%@ path=%@ ready=%d fd=%d errno=%d temp_socket=1 cloexec=1\n",
        control?@"CONTROL_V1_SOCKET":@"DISPLAY_SOCKET",path,ready,listener,saved]);
    if(ready)dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{JuiceAcceptLoop(self,listener,control);});
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
