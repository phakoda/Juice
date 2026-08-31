#import <UIKit/UIKit.h>
#import <errno.h>
#import <fcntl.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <spawn.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>

static id JuiceLaunchValue(id object,NSString *key){@try{return [object valueForKey:key];}@catch(__unused NSException *e){return nil;}}
static void JuiceLaunchSetValue(id object,NSString *key,id value){@try{[object setValue:value forKey:key];}@catch(__unused NSException *e){}}
static void JuiceLaunchAppend(id self,NSString *line){SEL s=NSSelectorFromString(@"append:");if([self respondsToSelector:s])((void(*)(id,SEL,id))objc_msgSend)(self,s,line);}
static id JuiceLaunchCallObject(id self,NSString *name){SEL s=NSSelectorFromString(name);return [self respondsToSelector:s]?((id(*)(id,SEL))objc_msgSend)(self,s):nil;}
static void JuiceLaunchCallVoid(id self,NSString *name){SEL s=NSSelectorFromString(name);if([self respondsToSelector:s])((void(*)(id,SEL))objc_msgSend)(self,s);}
static void JuiceLaunchReject(id self,NSString *message){SEL s=NSSelectorFromString(@"rejectLaunch:");if([self respondsToSelector:s])((void(*)(id,SEL,id))objc_msgSend)(self,s,message);else JuiceLaunchAppend(self,message);}
static void JuiceLaunchStop(id self,NSString *reason){SEL s=NSSelectorFromString(@"stopAllWineProcesses:");if([self respondsToSelector:s])((void(*)(id,SEL,id))objc_msgSend)(self,s,reason);}
static void JuiceLaunchFailAfterServer(id self,NSString *message){JuiceLaunchStop(self,@"launch-setup-failed");JuiceLaunchReject(self,message);}

static char **JuiceCopyStrings(NSArray<NSString *> *strings)
{
    char **result=calloc(strings.count+1,sizeof(*result));if(!result)return NULL;
    for(NSUInteger i=0;i<strings.count;i++)
    {
        const char *utf8=strings[i].UTF8String;
        if(!utf8||!(result[i]=strdup(utf8)))
        {for(NSUInteger j=0;j<i;j++)free(result[j]);free(result);return NULL;}
    }
    return result;
}
static void JuiceFreeStrings(char **strings){if(!strings)return;for(NSUInteger i=0;strings[i];i++)free(strings[i]);free(strings);}
static BOOL JuiceWhitespace(unichar c){static NSCharacterSet *set;static dispatch_once_t once;dispatch_once(&once,^{set=NSCharacterSet.whitespaceAndNewlineCharacterSet;});return [set characterIsMember:c];}

/* Parse the UIKit argument field without a shell. Quotes only group whitespace;
 * Windows backslashes are always literal. In particular, never collapse UNC
 * prefixes (\\server\share) or a quoted path ending in a backslash. A doubled
 * quote inside the same quoted group emits one literal quote. */
static NSArray<NSString *> *JuiceParseArguments(NSString *line,NSString **failure)
{
    if(!line.length)return @[];
    NSMutableArray *arguments=[NSMutableArray array];NSMutableString *current=[NSMutableString string];
    unichar quote=0;BOOL started=NO;
    for(NSUInteger i=0;i<line.length;i++)
    {
        unichar c=[line characterAtIndex:i];
        if(quote)
        {
            if(c==quote)
            {
                if(i+1<line.length&&[line characterAtIndex:i+1]==quote)
                {[current appendFormat:@"%C",quote];i++;started=YES;continue;}
                quote=0;started=YES;continue;
            }
            [current appendFormat:@"%C",c];started=YES;continue;
        }
        if(c=='"'||c=='\''){quote=c;started=YES;continue;}
        if(JuiceWhitespace(c))
        {
            if(started){[arguments addObject:[current copy]];[current setString:@""];started=NO;}
            continue;
        }
        [current appendFormat:@"%C",c];started=YES;
    }
    if(quote){if(failure)*failure=@"Arguments contain an unterminated quote.";return nil;}
    if(started)[arguments addObject:[current copy]];
    return arguments;
}

static int JuiceSpawnAttributes(posix_spawnattr_t *attributes)
{
    int error=posix_spawnattr_init(attributes);if(error)return error;
    short flags=POSIX_SPAWN_SETPGROUP;
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    flags|=POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    error=posix_spawnattr_setpgroup(attributes,0);
    if(!error)error=posix_spawnattr_setflags(attributes,flags);
    if(error)posix_spawnattr_destroy(attributes);
    return error;
}

static NSString *JuiceDecodeOutput(NSData *data)
{
    NSString *text=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
    if(!text)text=[[NSString alloc]initWithData:data encoding:NSISOLatin1StringEncoding];
    return text?:@"";
}

static void JuiceConsumeOutput(id self,int readFD,pid_t child,uint64_t generation,int inputFD)
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
        NSMutableData *pending=[NSMutableData data];uint8_t buffer[4096];
        for(;;)
        {
            ssize_t n=read(readFD,buffer,sizeof(buffer));if(n<0&&errno==EINTR)continue;if(n<=0)break;
            [pending appendBytes:buffer length:(NSUInteger)n];const uint8_t *bytes=pending.bytes;NSUInteger start=0;
            for(NSUInteger i=0;i<pending.length;i++)if(bytes[i]=='\n')
            {JuiceLaunchAppend(self,JuiceDecodeOutput([NSData dataWithBytes:bytes+start length:i+1-start]));start=i+1;}
            if(start)[pending replaceBytesInRange:NSMakeRange(0,start) withBytes:NULL length:0];
            if(pending.length>=64*1024){JuiceLaunchAppend(self,JuiceDecodeOutput(pending));[pending setLength:0];}
        }
        if(pending.length)JuiceLaunchAppend(self,JuiceDecodeOutput(pending));
    }close(readFD);

    /* stopAllWineProcesses increments launchGeneration before it signals the
     * old process group, then keeps the numeric PGID for a one-second SIGKILL
     * fence. Do not reap an exited stale tracer before that fence completes:
     * leaving it as a zombie prevents its PID/PGID from being recycled into a
     * replacement launch that the delayed kill could otherwise target. The
     * existing termination block performs the final WNOHANG reap. */
    __block BOOL staleGeneration=NO;
    dispatch_sync(dispatch_get_main_queue(),^{
        staleGeneration=[JuiceLaunchValue(self,@"launchGeneration") unsignedLongLongValue]!=generation;
    });
    if(staleGeneration)
    {
        JuiceLaunchAppend(self,[NSString stringWithFormat:
            @"PROCESS_GROUP_REAP_DEFERRED pgid=%d generation=%llu pid_reuse_fence=1\n",
            child,(unsigned long long)generation]);
        return;
    }

    int status=0;pid_t waited;do{waited=waitpid(child,&status,0);}while(waited<0&&errno==EINTR);
    int waitError=waited<0?errno:0;
    dispatch_async(dispatch_get_main_queue(),^{
        if([JuiceLaunchValue(self,@"launchGeneration") unsignedLongLongValue]!=generation)return;
        if([JuiceLaunchValue(self,@"child") intValue]==child)JuiceLaunchSetValue(self,@"child",@(-1));
        if([JuiceLaunchValue(self,@"childInput") intValue]==inputFD&&inputFD>=0){close(inputFD);JuiceLaunchSetValue(self,@"childInput",@(-1));}
        NSString *result=waited==child&&WIFEXITED(status)?[NSString stringWithFormat:@"exit=%d",WEXITSTATUS(status)]:
                         waited==child&&WIFSIGNALED(status)?[NSString stringWithFormat:@"signal=%d",WTERMSIG(status)]:
                         [NSString stringWithFormat:@"wait=%d errno=%d",waited,waitError];
        JuiceLaunchAppend(self,[NSString stringWithFormat:@"PROCESS_GROUP_EXITED pgid=%d %@\n",child,result]);
    });});
}

static void JuiceHardenedLaunch(id self,SEL _cmd)
{
    (void)_cmd;
    JuiceLaunchStop(self,@"new-launch");
    JuiceLaunchCallVoid(self,@"preparePrefix");

    UITextField *argsField=JuiceLaunchValue(self,@"argsField");NSString *failure=nil;
    NSArray<NSString *> *parts=JuiceParseArguments(argsField.text?:@"",&failure);
    if(!parts){JuiceLaunchReject(self,failure?:@"Arguments could not be parsed.");return;}

    NSString *grape=JuiceLaunchValue(self,@"grape");NSString *build=[grape stringByAppendingPathComponent:@"build/wine-ios"];
    NSString *loader=[build stringByAppendingPathComponent:@"loader/wine"];
    NSString *server=[build stringByAppendingPathComponent:@"server/wineserver"];
    NSString *tracer=[grape stringByAppendingPathComponent:@"tools/grape-trace-parent"];
    NSString *exe=JuiceLaunchCallObject(self,@"resolveExe");NSArray<NSString *> *environment=JuiceLaunchCallObject(self,@"environment");
    NSString *cwd=exe.stringByDeletingLastPathComponent;
    NSFileManager *files=NSFileManager.defaultManager;
    if(!grape.length||!exe.length||!environment.count||!cwd.length||![files isExecutableFileAtPath:loader]||
       ![files isExecutableFileAtPath:server]||![files isExecutableFileAtPath:tracer]||![files fileExistsAtPath:exe]||
       ![files fileExistsAtPath:cwd])
    {JuiceLaunchReject(self,@"The selected Wine runtime, executable, or working directory is incomplete.");return;}

    char **serverEnv=JuiceCopyStrings(environment);char **serverArgv=JuiceCopyStrings(@[server,@"-f"]);
    if(!serverEnv||!serverArgv){JuiceFreeStrings(serverEnv);JuiceFreeStrings(serverArgv);JuiceLaunchReject(self,@"Juice ran out of memory preparing wineserver arguments.");return;}
    posix_spawn_file_actions_t serverActions;int serverActionError=posix_spawn_file_actions_init(&serverActions);BOOL serverActionsReady=serverActionError==0;
    if(!serverActionError)serverActionError=posix_spawn_file_actions_addopen(&serverActions,1,"/dev/null",O_WRONLY,0);
    if(!serverActionError)serverActionError=posix_spawn_file_actions_adddup2(&serverActions,1,2);
    posix_spawnattr_t serverAttributes;int serverAttributeError=JuiceSpawnAttributes(&serverAttributes);BOOL serverAttributesReady=serverAttributeError==0;pid_t serverPID=-1;
    int serverResult=serverActionError?serverActionError:(serverAttributeError?serverAttributeError:
                     posix_spawn(&serverPID,server.fileSystemRepresentation,&serverActions,&serverAttributes,serverArgv,serverEnv));
    if(serverActionsReady)posix_spawn_file_actions_destroy(&serverActions);if(serverAttributesReady)posix_spawnattr_destroy(&serverAttributes);
    JuiceFreeStrings(serverArgv);JuiceFreeStrings(serverEnv);
    if(serverResult){JuiceLaunchSetValue(self,@"server",@(-1));JuiceLaunchReject(self,[NSString stringWithFormat:@"Juice could not start wineserver: %s",strerror(serverResult)]);return;}
    JuiceLaunchSetValue(self,@"server",@(serverPID));JuiceLaunchAppend(self,[NSString stringWithFormat:@"Wine server: 0 pid=%d pgid=%d hardened=1\n",serverPID,serverPID]);usleep(200000);

    NSMutableArray<NSString *> *childEnvironment=[environment mutableCopy];
    [childEnvironment addObject:[@"JUICE_LAUNCH_CWD=" stringByAppendingString:cwd]];
    char **env=JuiceCopyStrings(childEnvironment);
    NSMutableArray<NSString *> *arguments=[NSMutableArray arrayWithObjects:tracer,loader,exe,nil];[arguments addObjectsFromArray:parts];
    char **argv=JuiceCopyStrings(arguments);
    if(!env||!argv){JuiceFreeStrings(env);JuiceFreeStrings(argv);JuiceLaunchFailAfterServer(self,@"Juice ran out of memory preparing launch arguments.");return;}

    int outputPipe[2]={-1,-1},inputPipe[2]={-1,-1};
    if(pipe(outputPipe)||pipe(inputPipe))
    {
        int saved=errno;for(int i=0;i<2;i++){if(outputPipe[i]>=0)close(outputPipe[i]);if(inputPipe[i]>=0)close(inputPipe[i]);}
        JuiceFreeStrings(argv);JuiceFreeStrings(env);JuiceLaunchFailAfterServer(self,[NSString stringWithFormat:@"Juice could not create process pipes: %s",strerror(saved)]);return;
    }
    fcntl(outputPipe[0],F_SETFD,FD_CLOEXEC);fcntl(inputPipe[1],F_SETFD,FD_CLOEXEC);
    posix_spawn_file_actions_t actions;int actionError=posix_spawn_file_actions_init(&actions);BOOL actionsReady=actionError==0;
    if(!actionError)actionError=posix_spawn_file_actions_adddup2(&actions,inputPipe[0],0);
    if(!actionError)actionError=posix_spawn_file_actions_adddup2(&actions,outputPipe[1],1);
    if(!actionError)actionError=posix_spawn_file_actions_adddup2(&actions,outputPipe[1],2);
    if(!actionError)actionError=posix_spawn_file_actions_addclose(&actions,inputPipe[1]);
    if(!actionError)actionError=posix_spawn_file_actions_addclose(&actions,outputPipe[0]);
    if(!actionError&&inputPipe[0]!=0)actionError=posix_spawn_file_actions_addclose(&actions,inputPipe[0]);
    if(!actionError&&outputPipe[1]!=1&&outputPipe[1]!=2)actionError=posix_spawn_file_actions_addclose(&actions,outputPipe[1]);
    posix_spawnattr_t attributes;int attributeError=JuiceSpawnAttributes(&attributes);BOOL attributesReady=attributeError==0;pid_t child=-1;
    int result=actionError?actionError:(attributeError?attributeError:
               posix_spawn(&child,tracer.fileSystemRepresentation,&actions,&attributes,argv,env));
    if(actionsReady)posix_spawn_file_actions_destroy(&actions);if(attributesReady)posix_spawnattr_destroy(&attributes);
    close(inputPipe[0]);close(outputPipe[1]);JuiceFreeStrings(argv);JuiceFreeStrings(env);
    if(result)
    {
        close(inputPipe[1]);close(outputPipe[0]);JuiceLaunchSetValue(self,@"child",@(-1));JuiceLaunchSetValue(self,@"childInput",@(-1));
        JuiceLaunchFailAfterServer(self,[NSString stringWithFormat:@"Wine could not start %@: %s",exe.lastPathComponent,strerror(result)]);return;
    }

    JuiceLaunchSetValue(self,@"child",@(child));JuiceLaunchSetValue(self,@"childInput",@(inputPipe[1]));
    uint64_t generation=[JuiceLaunchValue(self,@"launchGeneration") unsignedLongLongValue]+1;JuiceLaunchSetValue(self,@"launchGeneration",@(generation));
    UISegmentedControl *mode=JuiceLaunchValue(self,@"mode");UIView *canvas=JuiceLaunchValue(self,@"canvas");BOOL cli=mode.selectedSegmentIndex==1;canvas.hidden=cli;
    JuiceLaunchAppend(self,[NSString stringWithFormat:@"\n%@ launch %@: 0 pid=%d pgid=%d generation=%llu argc=%lu cwd=%@ cwd_transport=trace-parent hardened=1\n",cli?@"CLI":@"GUI",exe,child,child,(unsigned long long)generation,(unsigned long)arguments.count,cwd]);
    JuiceConsumeOutput(self,outputPipe[0],child,generation,inputPipe[1]);
}

__attribute__((constructor(450)))
static void JuiceInstallLaunchHardening(void)
{
    Class cls=NSClassFromString(@"JuiceController");if(!cls)return;
    Method method=class_getInstanceMethod(cls,NSSelectorFromString(@"launchTapped"));if(method)method_setImplementation(method,(IMP)JuiceHardenedLaunch);
}
