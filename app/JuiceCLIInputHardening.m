#import <UIKit/UIKit.h>
#import <errno.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>

static BOOL (*JuiceCLIOriginalShouldReturn)(id,SEL,UITextField *);

static id JuiceCLIValue(id object,NSString *key){@try{return [object valueForKey:key];}@catch(__unused NSException *e){return nil;}}
static void JuiceCLISetValue(id object,NSString *key,id value){@try{[object setValue:value forKey:key];}@catch(__unused NSException *e){}}
static void JuiceCLIAppend(id self,NSString *line){SEL s=NSSelectorFromString(@"append:");if([self respondsToSelector:s])((void(*)(id,SEL,id))objc_msgSend)(self,s,line);}

static BOOL JuiceCLIWriteAll(int fd,const void *buffer,size_t length)
{
    const uint8_t *cursor=buffer;
    while(length)
    {
        ssize_t count=write(fd,cursor,length);
        if(count<0&&errno==EINTR)continue;
        if(count<=0)return NO;
        cursor+=count;
        length-=(size_t)count;
    }
    return YES;
}

static BOOL JuiceCLIShouldReturn(id self,SEL _cmd,UITextField *field)
{
    UITextField *stdinField=JuiceCLIValue(self,@"stdinField");
    if(field!=stdinField)
        return JuiceCLIOriginalShouldReturn?JuiceCLIOriginalShouldReturn(self,_cmd,field):YES;

    int fd=[JuiceCLIValue(self,@"childInput") intValue];
    if(fd<0)
    {
        JuiceCLIAppend(self,@"CLI_STDIN_REJECTED reason=no-child-input\n");
        [field resignFirstResponder];
        return YES;
    }

    NSString *line=[(field.text?:@"") stringByAppendingString:@"\r\n"];
    NSData *wire=[line dataUsingEncoding:NSUTF8StringEncoding];
    BOOL written=wire.length?JuiceCLIWriteAll(fd,wire.bytes,wire.length):YES;
    if(!written)
    {
        int saved=errno;
        close(fd);
        if([JuiceCLIValue(self,@"childInput") intValue]==fd)JuiceCLISetValue(self,@"childInput",@(-1));
        JuiceCLIAppend(self,[NSString stringWithFormat:@"CLI_STDIN_FAILED fd=%d errno=%d\n",fd,saved]);
    }
    else
    {
        JuiceCLIAppend(self,[@"> " stringByAppendingString:line]);
        field.text=@"";
    }
    [field resignFirstResponder];
    return YES;
}

__attribute__((constructor(430)))
static void JuiceInstallCLIInputHardening(void)
{
    Class cls=NSClassFromString(@"JuiceController");if(!cls)return;
    Method method=class_getInstanceMethod(cls,NSSelectorFromString(@"textFieldShouldReturn:"));if(!method)return;
    JuiceCLIOriginalShouldReturn=(BOOL(*)(id,SEL,UITextField *))method_setImplementation(method,(IMP)JuiceCLIShouldReturn);
}
