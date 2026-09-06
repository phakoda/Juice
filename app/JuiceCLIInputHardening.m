#import <UIKit/UIKit.h>
#import "JuiceAsyncWriter.h"
#import <errno.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>

#define JUICE_CLI_MAX_LINE_BYTES (64u * 1024u)

static BOOL (*JuiceCLIOriginalShouldReturn)(id,SEL,UITextField *);
static void (*JuiceCLIOriginalStop)(id,SEL,NSString *);
static char JuiceCLIWriterKey;

@interface JuiceCLIWriterState : NSObject
@property(nonatomic) int fd;
@property(nonatomic) uint64_t generation;
@property(nonatomic,strong) JuiceAsyncWriter *writer;
@end
@implementation JuiceCLIWriterState
@end

static id JuiceCLIValue(id object,NSString *key){@try{return [object valueForKey:key];}@catch(__unused NSException *e){return nil;}}
static void JuiceCLISetValue(id object,NSString *key,id value){@try{[object setValue:value forKey:key];}@catch(__unused NSException *e){}}
static void JuiceCLIAppend(id self,NSString *line){SEL s=NSSelectorFromString(@"append:");if([self respondsToSelector:s])((void(*)(id,SEL,id))objc_msgSend)(self,s,line);}

static void JuiceCLIStop(id self,SEL _cmd,NSString *reason)
{
    JuiceCLIWriterState *state=objc_getAssociatedObject(self,&JuiceCLIWriterKey);
    [state.writer cancel];
    objc_setAssociatedObject(self,&JuiceCLIWriterKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if(JuiceCLIOriginalStop)JuiceCLIOriginalStop(self,_cmd,reason);
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
    NSString *text=field.text?:@"";
    if(text.length>JUICE_CLI_MAX_LINE_BYTES||[text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>JUICE_CLI_MAX_LINE_BYTES)
    {
        JuiceCLIAppend(self,@"CLI_STDIN_REJECTED reason=line-too-large limit=65536\n");
        return NO;
    }
    NSString *line=[text stringByAppendingString:@"\r\n"];
    NSData *wire=[line dataUsingEncoding:NSUTF8StringEncoding];
    uint64_t generation=[JuiceCLIValue(self,@"launchGeneration") unsignedLongLongValue];
    JuiceCLIWriterState *state=objc_getAssociatedObject(self,&JuiceCLIWriterKey);
    if(!state||state.fd!=fd||state.generation!=generation)
    {
        [state.writer cancel];
        state=[JuiceCLIWriterState new];state.fd=fd;state.generation=generation;
        __weak id weakSelf=self;
        __weak JuiceCLIWriterState *weakState=state;
        state.writer=[[JuiceAsyncWriter alloc]initWithFD:fd socket:NO limit:2u*JUICE_CLI_MAX_LINE_BYTES failure:^(int error){
            dispatch_async(dispatch_get_main_queue(),^{
                id target=weakSelf;
                JuiceCLIWriterState *failed=weakState;
                if(!target||!failed||objc_getAssociatedObject(target,&JuiceCLIWriterKey)!=failed)return;
                if([JuiceCLIValue(target,@"launchGeneration") unsignedLongLongValue]==generation&&
                   [JuiceCLIValue(target,@"childInput") intValue]==fd)
                {close(fd);JuiceCLISetValue(target,@"childInput",@(-1));}
                objc_setAssociatedObject(target,&JuiceCLIWriterKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                JuiceCLIAppend(target,[NSString stringWithFormat:@"CLI_STDIN_FAILED fd=%d errno=%d\n",fd,error]);
            });
        }];
        objc_setAssociatedObject(self,&JuiceCLIWriterKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if(!wire||!state.writer||![state.writer enqueueData:wire])
    {
        JuiceCLIAppend(self,[NSString stringWithFormat:@"CLI_STDIN_REJECTED fd=%d errno=%d text_retained=1\n",fd,errno]);
        return NO;
    }
    JuiceCLIAppend(self,[@"> [queued] " stringByAppendingString:line]);
    field.text=@"";
    [field resignFirstResponder];
    return YES;
}

__attribute__((constructor(430)))
static void JuiceInstallCLIInputHardening(void)
{
    Class cls=NSClassFromString(@"JuiceController");if(!cls)return;
    Method method=class_getInstanceMethod(cls,NSSelectorFromString(@"textFieldShouldReturn:"));
    if(method)JuiceCLIOriginalShouldReturn=(BOOL(*)(id,SEL,UITextField *))method_setImplementation(method,(IMP)JuiceCLIShouldReturn);
    Method stop=class_getInstanceMethod(cls,NSSelectorFromString(@"stopAllWineProcesses:"));
    if(stop)JuiceCLIOriginalStop=(void(*)(id,SEL,NSString *))method_setImplementation(stop,(IMP)JuiceCLIStop);
}
