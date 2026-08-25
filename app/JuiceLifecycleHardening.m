#import <UIKit/UIKit.h>
#import <errno.h>
#import <fcntl.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

static void (*JuiceLifecycleOriginalViewDidLoad)(id,SEL);
static char JuiceLifecycleObserverTokensKey;

static id JuiceLifecycleValue(id object,NSString *key){@try{return [object valueForKey:key];}@catch(__unused NSException *e){return nil;}}
static void JuiceLifecycleSetValue(id object,NSString *key,id value){@try{[object setValue:value forKey:key];}@catch(__unused NSException *e){}}
static void JuiceLifecycleAppend(id self,NSString *line){SEL s=NSSelectorFromString(@"append:");if([self respondsToSelector:s])((void(*)(id,SEL,id))objc_msgSend)(self,s,line);}

static BOOL JuiceDescriptorAlive(int fd)
{
    if(fd<0)return NO;errno=0;if(fcntl(fd,F_GETFD)>=0)return YES;return errno!=EBADF;
}

static BOOL JuiceListenerOwnsFD(int fd,NSString *path)
{
    if(fd<0||!path.length)return NO;
    int accepting=0;socklen_t acceptingLength=sizeof(accepting);
    if(getsockopt(fd,SOL_SOCKET,SO_ACCEPTCONN,&accepting,&acceptingLength)||!accepting)return NO;
    struct sockaddr_un address={0};socklen_t addressLength=sizeof(address);
    if(getsockname(fd,(struct sockaddr *)&address,&addressLength)||address.sun_family!=AF_UNIX)return NO;
    const char *wire=path.fileSystemRepresentation;
    return wire&&address.sun_path[0]&&strcmp(address.sun_path,wire)==0;
}

static void JuiceMarkCloseOnExec(int fd)
{
    if(fd<0)return;int flags=fcntl(fd,F_GETFD);if(flags>=0)fcntl(fd,F_SETFD,flags|FD_CLOEXEC);
}

static BOOL JuiceListenerNeedsRestart(id self,NSString *fdKey,NSString *pathKey)
{
    int fd=[JuiceLifecycleValue(self,fdKey) intValue];NSString *path=JuiceLifecycleValue(self,pathKey);
    if(!JuiceListenerOwnsFD(fd,path))return YES;
    return !path.length||access(path.fileSystemRepresentation,F_OK)!=0;
}

static void JuiceRestartListener(id self,NSString *fdKey,NSString *pathKey,NSString *selectorName,NSString *label)
{
    if(!JuiceListenerNeedsRestart(self,fdKey,pathKey))return;
    int oldFD=[JuiceLifecycleValue(self,fdKey) intValue];
    NSString *oldPath=JuiceLifecycleValue(self,pathKey);
    BOOL owned=JuiceListenerOwnsFD(oldFD,oldPath);
    if(owned)close(oldFD);
    JuiceLifecycleSetValue(self,fdKey,@(-1));
    if(oldPath.length)unlink(oldPath.fileSystemRepresentation);
    SEL selector=NSSelectorFromString(selectorName);
    if([self respondsToSelector:selector])
    {
        JuiceLifecycleAppend(self,[NSString stringWithFormat:
            @"APP_LIFECYCLE listener_restart=%@ old_fd=%d old_path=%@ owned=%d reused_fd=%d\n",
            label,oldFD,oldPath?:@"",owned,oldFD>=0&&JuiceDescriptorAlive(oldFD)&&!owned]);
        ((void(*)(id,SEL))objc_msgSend)(self,selector);
    }
}

static void JuiceEnteredBackground(id self)
{
    JuiceLifecycleSetValue(self,@"inputClient",@(-1));JuiceLifecycleSetValue(self,@"inputHwnd",@0);
    if([self isKindOfClass:UIViewController.class])[((UIViewController *)self).view endEditing:YES];
    JuiceLifecycleAppend(self,[NSString stringWithFormat:@"APP_LIFECYCLE background child=%d server=%d display_fd=%d control_fd=%d\n",
        [JuiceLifecycleValue(self,@"child") intValue],[JuiceLifecycleValue(self,@"server") intValue],
        [JuiceLifecycleValue(self,@"listenFD") intValue],[JuiceLifecycleValue(self,@"controlListenFD") intValue]]);
}

static void JuiceEnteredForeground(id self)
{
    JuiceRestartListener(self,@"listenFD",@"socketPath",@"startDisplayServer",@"display");
    JuiceRestartListener(self,@"controlListenFD",@"controlSocketPath",@"startControlServer",@"control");
    JuiceLifecycleAppend(self,[NSString stringWithFormat:@"APP_LIFECYCLE foreground display_fd=%d control_fd=%d clients=%lu\n",
        [JuiceLifecycleValue(self,@"listenFD") intValue],[JuiceLifecycleValue(self,@"controlListenFD") intValue],
        (unsigned long)[JuiceLifecycleValue(self,@"clients") count]]);
}

static void JuiceWillTerminate(id self)
{
    NSArray<NSString *> *fdKeys=@[@"listenFD",@"controlListenFD"];
    NSArray<NSString *> *pathKeys=@[@"socketPath",@"controlSocketPath"];
    for(NSUInteger i=0;i<fdKeys.count;i++)
    {
        int fd=[JuiceLifecycleValue(self,fdKeys[i]) intValue];NSString *path=JuiceLifecycleValue(self,pathKeys[i]);
        BOOL owned=JuiceListenerOwnsFD(fd,path);if(owned)close(fd);
        JuiceLifecycleSetValue(self,fdKeys[i],@(-1));if(path.length)unlink(path.fileSystemRepresentation);
    }
    JuiceLifecycleAppend(self,@"APP_LIFECYCLE terminate listeners_closed=1\n");
}

static void JuiceLifecycleViewDidLoad(id self,SEL _cmd)
{
    if(JuiceLifecycleOriginalViewDidLoad)JuiceLifecycleOriginalViewDidLoad(self,_cmd);

    JuiceMarkCloseOnExec([JuiceLifecycleValue(self,@"gamepadFD") intValue]);
    NSFileHandle *log=JuiceLifecycleValue(self,@"persistentLogHandle");
    if([log isKindOfClass:NSFileHandle.class])JuiceMarkCloseOnExec(log.fileDescriptor);

    NSNotificationCenter *center=NSNotificationCenter.defaultCenter;__weak id weakSelf=self;
    id background=[center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){id strong=weakSelf;if(strong)JuiceEnteredBackground(strong);}];
    id foreground=[center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){id strong=weakSelf;if(strong)JuiceEnteredForeground(strong);}];
    id terminate=[center addObserverForName:UIApplicationWillTerminateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){id strong=weakSelf;if(strong)JuiceWillTerminate(strong);}];
    objc_setAssociatedObject(self,&JuiceLifecycleObserverTokensKey,@[background,foreground,terminate],OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    JuiceLifecycleAppend(self,@"APP_LIFECYCLE_READY listener_recovery=1 descriptor_cloexec=1 listener_identity=1\n");
}

__attribute__((constructor(420)))
static void JuiceInstallLifecycleHardening(void)
{
    Class cls=NSClassFromString(@"JuiceController");if(!cls)return;
    Method view=class_getInstanceMethod(cls,@selector(viewDidLoad));if(!view)return;
    JuiceLifecycleOriginalViewDidLoad=(void(*)(id,SEL))method_setImplementation(view,(IMP)JuiceLifecycleViewDidLoad);
}
