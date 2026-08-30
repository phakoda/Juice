#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define JUICE_TEXT_MAGIC 0x4a554943u
#define JUICE_TEXT_MESSAGE 101u
#define JUICE_TEXT_CHUNK_BYTES (60u * 1024u)
#define JUICE_TEXT_MAX_PASTE_BYTES (1024u * 1024u)

typedef struct
{
    uint32_t magic,type,size;
    uint64_t hwnd;
    int32_t x,y,width,height;
    uint32_t stride,flags;
} JuiceTextMsg;

static void (*JuiceOriginalTextViewDidLoad)(id,SEL);
static NSArray<UIKeyCommand *> *(*JuiceOriginalCanvasKeyCommands)(id,SEL);

static id JuiceTextValue(id object,NSString *key)
{
    @try{return [object valueForKey:key];}
    @catch(__unused NSException *exception){return nil;}
}
static void JuiceTextAppend(id self,NSString *line)
{
    SEL selector=NSSelectorFromString(@"append:");
    if([self respondsToSelector:selector])((void(*)(id,SEL,id))objc_msgSend)(self,selector,line);
}
static BOOL JuiceTextFDConnected(id self,int fd)
{
    if(fd<0)return NO;
    id clients=JuiceTextValue(self,@"clients");
    if(![clients isKindOfClass:NSArray.class])return YES;
    @synchronized(clients){return [clients containsObject:@(fd)];}
}
static int JuiceTextClientForHWND(id self,uint64_t hwnd)
{
    NSDictionary *windows=JuiceTextValue(self,@"wineWindows");
    if(hwnd&&[windows isKindOfClass:NSDictionary.class])
    {
        id state=windows[@(hwnd)];
        int fd=[JuiceTextValue(state,@"clientFD") intValue];
        if(JuiceTextFDConnected(self,fd))return fd;
    }
    int active=[JuiceTextValue(self,@"activeClient") intValue];
    return JuiceTextFDConnected(self,active)?active:-1;
}
static BOOL JuiceTextSendMessage(id self,JuiceTextMsg *message,NSData *payload,int fd)
{
    SEL selector=NSSelectorFromString(@"sendMessage:payload:toFD:");
    if(![self respondsToSelector:selector])return NO;
    return ((BOOL(*)(id,SEL,JuiceTextMsg *,id,int))objc_msgSend)(self,selector,message,payload,fd);
}
static BOOL JuiceSendTextPayload(id self,NSData *payload,uint64_t hwnd,int client,NSUInteger *chunkCount)
{
    if(!payload.length||!hwnd||client<0)return NO;
    NSUInteger offset=0,chunks=0;
    while(offset<payload.length)
    {
        NSUInteger length=MIN((NSUInteger)JUICE_TEXT_CHUNK_BYTES,payload.length-offset);
        length&=~(NSUInteger)1; /* UTF-16LE code-unit alignment. */
        if(!length)return NO;
        NSData *part=[payload subdataWithRange:NSMakeRange(offset,length)];
        JuiceTextMsg message={JUICE_TEXT_MAGIC,JUICE_TEXT_MESSAGE,0,hwnd,0,0,0,0,0,0};
        if(!JuiceTextSendMessage(self,&message,part,client))return NO;
        offset+=length;chunks++;
    }
    if(chunkCount)*chunkCount=chunks;
    return YES;
}
static BOOL JuiceSendText(id self,NSString *text,NSString *source)
{
    if(!text.length)return NO;
    id canvas=JuiceTextValue(self,@"canvas");
    uint64_t hwnd=[JuiceTextValue(canvas,@"hwnd") unsignedLongLongValue];
    int client=JuiceTextClientForHWND(self,hwnd);
    if(!hwnd||client<0)
    {
        JuiceTextAppend(self,[NSString stringWithFormat:
            @"GUI_TEXT_REJECTED reason=no-selected-client source=%@ hwnd=0x%llx fd=%d\n",
            source?:@"unknown",(unsigned long long)hwnd,client]);
        return NO;
    }

    NSData *payload=[text dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    if(!payload.length)return NO;
    if(payload.length>JUICE_TEXT_MAX_PASTE_BYTES)
    {
        JuiceTextAppend(self,[NSString stringWithFormat:
            @"GUI_TEXT_REJECTED reason=too-large source=%@ bytes=%lu max=%u\n",
            source?:@"unknown",(unsigned long)payload.length,JUICE_TEXT_MAX_PASTE_BYTES]);
        return NO;
    }

    NSUInteger chunks=0;
    BOOL delivered=JuiceSendTextPayload(self,payload,hwnd,client,&chunks);
    JuiceTextAppend(self,[NSString stringWithFormat:
        @"GUI_TEXT_SENT hwnd=0x%llx fd=%d source=%@ utf16_units=%lu bytes=%lu chunks=%lu delivered=%d selected_only=1\n",
        (unsigned long long)hwnd,client,source?:@"unknown",
        (unsigned long)(payload.length/2),(unsigned long)payload.length,
        (unsigned long)chunks,delivered]);
    return delivered;
}
static void JuiceChunkedSendGuiText(id self,SEL _cmd)
{
    (void)_cmd;
    UITextField *field=JuiceTextValue(self,@"guiTextField");
    if(![field isKindOfClass:UITextField.class])return;
    NSString *text=field.text?:@"";
    if(!text.length)return;
    if(JuiceSendText(self,text,@"field"))field.text=@"";
}
static void JuicePasteClipboard(id self,SEL _cmd,id sender)
{
    (void)_cmd;(void)sender;
    NSString *text=UIPasteboard.generalPasteboard.string;
    if(!text.length)
    {
        JuiceTextAppend(self,@"CLIPBOARD_PASTE_REJECTED reason=no-text\n");
        return;
    }
    JuiceSendText(self,text,@"ios-clipboard");
}
static id JuiceControllerForResponder(UIResponder *responder)
{
    UIResponder *cursor=responder;
    SEL paste=NSSelectorFromString(@"juice_pasteIOSClipboard:");
    while(cursor)
    {
        if([cursor respondsToSelector:paste])return cursor;
        cursor=cursor.nextResponder;
    }
    return nil;
}
static void JuiceCanvasPasteCommand(id self,SEL _cmd,UIKeyCommand *command)
{
    (void)_cmd;
    id controller=JuiceControllerForResponder(self);
    SEL paste=NSSelectorFromString(@"juice_pasteIOSClipboard:");
    if(controller)((void(*)(id,SEL,id))objc_msgSend)(controller,paste,command);
}
static NSArray<UIKeyCommand *> *JuiceCanvasKeyCommands(id self,SEL _cmd)
{
    NSArray<UIKeyCommand *> *base=JuiceOriginalCanvasKeyCommands?JuiceOriginalCanvasKeyCommands(self,_cmd):@[];
    NSMutableArray<UIKeyCommand *> *commands=[base mutableCopy]?:[NSMutableArray array];
    UIKeyCommand *paste=[UIKeyCommand keyCommandWithInput:@"v" modifierFlags:UIKeyModifierCommand
                                                    action:NSSelectorFromString(@"juice_pasteClipboardKeyCommand:")];
    paste.discoverabilityTitle=@"Paste into Windows";
    [commands addObject:paste];
    return commands;
}
static void JuiceTextViewDidLoad(id self,SEL _cmd)
{
    if(JuiceOriginalTextViewDidLoad)JuiceOriginalTextViewDidLoad(self,_cmd);
    UIStackView *form=JuiceTextValue(self,@"form");
    if(![form isKindOfClass:UIStackView.class])return;
    UIButton *paste=[UIButton buttonWithType:UIButtonTypeSystem];
    [paste setTitle:@"Paste iOS Clipboard into Windows" forState:UIControlStateNormal];
    paste.accessibilityIdentifier=@"juice.paste-ios-clipboard";
    [paste addTarget:self action:NSSelectorFromString(@"juice_pasteIOSClipboard:")
      forControlEvents:UIControlEventTouchUpInside];
    [form addArrangedSubview:paste];
}

__attribute__((constructor(375)))
static void JuiceInstallTextInputHardening(void)
{
    Class controller=NSClassFromString(@"JuiceController");
    if(controller)
    {
        class_addMethod(controller,NSSelectorFromString(@"juice_pasteIOSClipboard:"),(IMP)JuicePasteClipboard,"v@:@");
        Method send=class_getInstanceMethod(controller,NSSelectorFromString(@"sendGuiTextTapped"));
        if(send)method_setImplementation(send,(IMP)JuiceChunkedSendGuiText);
        Method view=class_getInstanceMethod(controller,@selector(viewDidLoad));
        if(view)JuiceOriginalTextViewDidLoad=(void(*)(id,SEL))method_setImplementation(view,(IMP)JuiceTextViewDidLoad);
    }

    Class canvas=NSClassFromString(@"WineCanvas");
    if(canvas)
    {
        class_addMethod(canvas,NSSelectorFromString(@"juice_pasteClipboardKeyCommand:"),(IMP)JuiceCanvasPasteCommand,"v@:@");
        Method inherited=class_getInstanceMethod(class_getSuperclass(canvas),@selector(keyCommands));
        JuiceOriginalCanvasKeyCommands=inherited?(NSArray<UIKeyCommand *> *(*)(id,SEL))method_getImplementation(inherited):NULL;
        if(!class_addMethod(canvas,@selector(keyCommands),(IMP)JuiceCanvasKeyCommands,"@@:"))
        {
            Method own=class_getInstanceMethod(canvas,@selector(keyCommands));
            if(own)JuiceOriginalCanvasKeyCommands=(NSArray<UIKeyCommand *> *(*)(id,SEL))method_setImplementation(own,(IMP)JuiceCanvasKeyCommands);
        }
    }
}
