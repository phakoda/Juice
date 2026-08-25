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

/* Parse the UIKit argument field without a shell. Quotes group whitespace;
 * ordinary Windows path backslashes remain literal. */
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
            if(c==quote){quote=0;started=YES;continue;}
            if(c=='\\'&&i+1<line.length)
            {
                unichar next=[line characterAtIndex:i+1];
                if(next==quote||next=='\\'){[current appendFormat:@"%C",next];i++;started=YES;continue;}
            }
            [current appendFormat:@"%C",c];started=YES;continue;
        }
        if(c=='"'||c=='\''){quote=c;started=YES;continue;}
        if(JuiceWhitespace(c))
        {
            if(started){[arguments addObject:[current copy]];[current setString:@""];started=NO;}
            continue;
        }
        if(c=='\\'&&i+1<line.length)
        {
            unichar next=[line characterAtIndex:i+1];
            if(JuiceWhitespace(next)||next=='"'||next=='\''||next=='\\')
            {[current appendFormat:@"%C",next];i++;started=YES;continue;}
        }
        [current appendFormat:@"%C",c];started=YES;
    }
    if(quote){if(failure)*failure=@"Arguments contain an unterminated quote.";return nil;}
    if(started)[arguments addObject:[current copy]];
    return arguments;
}

static BOOL JuiceSpawnAttributes(posix_spawnattr_t *attributes)
{
    if(posix_spawnattr_init(attributes))return NO;
    short flags=POSIX_SPAWN_SETPGROUP;
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    flags|=POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    if(posix_spawnattr_setpgroup(attributes,0)||posix_spawnattr_setflags(attributes,flags))
    {posix_spawnattr_destroy(attributes);return NO;}
    return YES;
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
    int status=0;pid_t waited;do{waited=waitpid(child,&status,0);}while(waited<0&&errno==EINTR);
    dispatch_async(dispatch_get_main_queue(),^{
        if([JuiceLaunchValue(self,@"launchGeneration") unsignedLongLongValue]!=generation)return;
        if([JuiceLaunchValue(self,@"child") intValue]==child)JuiceLaunchSetValue(self,@"child",@(-1));
        if([JuiceLaunchValue(self,@"childInput") intValue]==inputFD&&inputFD>=0){close(inputFD);JuiceLaunchSetValue(self,@"childInput",@(-1));}
        NSString *result=waited==child&&WIFEXITED(status)?[NSString stringWithFormat:@"exit=%d",WEXITSTATUS(status)]:
                         waited==child&&WIFSIGNALED(status)?[NSString stringWithFormat:@"signal=%d",WTERMSIG(status)]:
                         [NSString stringWithFormat:@"wait=%d errno=%d",waited,errno];
        JuiceLaunchAppend(self,[NSString stringWithFormat:@"PROCESS_GROUP_EXITED pgid=%d %@\n",child,result]);
    });});
}

static void JuiceHardenedLaunch(id self,SEL _cmd)
{
    (void)_cmd;
    SEL stop=NSSelectorFromString(@"stopAllWineProcesses:");
    if([self respondsToSelector:stop])((void(*)(id,SEL,id))objc_msgSend)(self,stop,@"new-launch");
    JuiceLaunchCallVoid(self,@"preparePrefix");

    UITextField *argsField=JuiceLaunchValue(self,@"argsField");NSString *failure=nil;
    NSArray<NSString *> *parts=JuiceParseArguments(argsField.text?:@"",&failure);
    if(!parts){JuiceLaunchReject(self,failure?:@"Arguments could not be parsed.");return;}

    NSString *grape=JuiceLaunchValue(self,@"grape");NSString *build=[grape stringByAppendingPathComponent:@"build/wine-ios"];
    NSString *loader=[build stringByAppendingPathComponent:@"loader/wine"];
    NSString *server=[build stringByAppendingPathComponent:@"server/wineserver"];
    NSString *tracer=[grape stringByAppendingPathComponent:@"tools/grape-trace-parent"];
    NSString *exe=JuiceLaunchCallObject(self,@"resolveExe");NSArray<NSString *> *environment=JuiceLaunchCallObject(self,@"environment");
    if(!grape.length||!exe.length||!environment.count||![NSFileManager.defaultManager isExecutableFileAtPath:loader]||![NSFileManager.defaultManager isExecutableFileAtPath:tracer])
    {JuiceLaunchReject(self,@"The selected Wine runtime is incomplete or not executable.");return;}

    char **env=JuiceCopyStrings(environment);char **serverArgv=JuiceCopyStrings(@[server,@"-f"]);
    if(!env||!serverArgv){JuiceFreeStrings(env);JuiceFreeStrings(serverArgv);JuiceLaunchReject(self,@"Juice ran out of memory preparing wineserver arguments.");return;}
    posix_spawn_file_actions_t serverActions;BOOL serverActionsReady=posix_spawn_file_actions_init(&serverActions)==0;int serverActionError=serverActionsReady?0:ENOMEM;
    if(!serverActionError)serverActionError=posix_spawn_file_actions_addopen(&serverActions,1,"/dev/null",O_WRONLY,0);
    if(!serverActionError)serverActionError=posix_spawn_file_actions_adddup2(&serverActions,1,2);
    posix_spawnattr_t serverAttributes;BOOL serverAttributesReady=JuiceSpawnAttributes(&serverAttributes);pid_t serverPID=-1;
    int serverResult=serverActionError?:posix_spawn(&serverPID,server.fileSystemRepresentation,serverActionsReady?&serverActions:NULL,serverAttributesReady?&serverAttributes:NULL,serverArgv,env);
    if(serverActionsReady)posix_spawn_file_actions_destroy(&serverActions);if(serverAttributesReady)posix_spawnattr_destroy(&serverAttributes);JuiceFreeStrings(serverArgv);
    if(serverResult){JuiceFreeStrings(env);JuiceLaunchSetValue(self,@"server",@(-1));JuiceLaunchReject(self,[NSString stringWithFormat:@"Juice could not start wineserver: %s",strerror(serverResult)]);return;}
    JuiceLaunchSetValue(self,@"server",@(serverPID));JuiceLaunchAppend(self,[NSString stringWithFormat:@"Wine server: 0 pid=%d pgid=%d hardened=1\n",serverPID,serverPID]);usleep(200000);

    NSMutableArray<NSString *> *arguments=[NSMutableArray arrayWithObjects:tracer,loader,exe,nil];[arguments addObjectsFromArray:parts];char **argv=JuiceCopyStrings(arguments);
    if(!argv){JuiceFreeStrings(env);JuiceLaunchReject(self,@"Juice ran out of memory preparing launch arguments.");return;}
    int outputPipe[2]={-1,-1},inputPipe[2]={-1,-1};
    if(pipe(outputPipe)||pipe(inputPipe))
    {
        int saved=errno;for(int i=0;i<2;i++){if(outputPipe[i]>=0)close(outputPipe[i]);if(inputPipe[i]>=0)close(inputPipe[i]);}
        JuiceFreeStrings(argv);JuiceFreeStrings(env);JuiceLaunchReject(self,[NSString stringWithFormat:@"Juice could not create process pipes: %s",strerror(saved)]);return;
    }
    fcntl(outputPipe[0],F_SETFD,FD_CLOEXEC);fcntl(inputPipe[1],F_SETFD,FD_CLOEXEC);
    posix_spawn_file_actions_t actions;BOOL actionsReady=posix_spawn_file_actions_init(&actions)==0;int actionError=actionsReady?0:ENOMEM;
    if(!actionError)actionError=posix_spawn_file_actions_adddup2(&actions,inputPipe[0],0);
    if(!actionError)actionError=posix_spawn_file_actions_adddup2(&actions,outputPipe[1],1);
    if(!actionError)actionError=posix_spawn_file_actions_adddup2(&actions,outputPipe[1],2);
    if(!actionError)actionError=posix_spawn_file_actions_addclose(&actions,inputPipe[1]);
    if(!actionError)actionError=posix_spawn_file_actions_addclose(&actions,outputPipe[0]);
    if(!actionError&&inputPipe[0]!=0)actionError=posix_spawn_file_actions_addclose(&actions,inputPipe[0]);
    if(!actionError&&outputPipe[1]!=1&&outputPipe[1]!=2)actionError=posix_spawn_file_actions_addclose(&actions,outputPipe[1]);
#if defined(__APPLE__)
    NSString *cwd=exe.stringByDeletingLastPathComponent;
    if(!actionError&&[exe containsString:@"/"]&&cwd.length)actionError=posix_spawn_file_actions_addchdir_np(&actions,cwd.fileSystemRepresentation);
#else
    NSString *cwd=exe.stringByDeletingLastPathComponent;
#endif
    posix_spawnattr_t attributes;BOOL attributesReady=JuiceSpawnAttributes(&attributes);pid_t child=-1;
    int result=actionError?:posix_spawn(&child,tracer.fileSystemRepresentation,actionsReady?&actions:NULL,attributesReady?&attributes:NULL,argv,env);
    if(actionsReady)posix_spawn_file_actions_destroy(&actions);if(attributesReady)posix_spawnattr_destroy(&attributes);
    close(inputPipe[0]);close(outputPipe[1]);JuiceFreeStrings(argv);JuiceFreeStrings(env);
    if(result)
    {close(inputPipe[1]);close(outputPipe[0]);JuiceLaunchSetValue(self,@"child",@(-1));JuiceLaunchSetValue(self,@"childInput",@(-1));JuiceLaunchReject(self,[NSString stringWithFormat:@"Wine could not start %@: %s",exe.lastPathComponent,strerror(result)]);return;}

    JuiceLaunchSetValue(self,@"child",@(child));JuiceLaunchSetValue(self,@"childInput",@(inputPipe[1]));
    uint64_t generation=[JuiceLaunchValue(self,@"launchGeneration") unsignedLongLongValue]+1;JuiceLaunchSetValue(self,@"launchGeneration",@(generation));
    UISegmentedControl *mode=JuiceLaunchValue(self,@"mode");UIView *canvas=JuiceLaunchValue(self,@"canvas");BOOL cli=mode.selectedSegmentIndex==1;canvas.hidden=cli;
    JuiceLaunchAppend(self,[NSString stringWithFormat:@"\n%@ launch %@: 0 pid=%d pgid=%d generation=%llu argc=%lu cwd=%@ hardened=1\n",cli?@"CLI":@"GUI",exe,child,child,(unsigned long long)generation,(unsigned long)arguments.count,cwd]);
    JuiceConsumeOutput(self,outputPipe[0],child,generation,inputPipe[1]);
}

__attribute__((constructor))
static void JuiceInstallLaunchHardening(void)
{
    Class cls=NSClassFromString(@"JuiceController");if(!cls)return;
    Method method=class_getInstanceMethod(cls,NSSelectorFromString(@"launchTapped"));if(method)method_setImplementation(method,(IMP)JuiceHardenedLaunch);
}
