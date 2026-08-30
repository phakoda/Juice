#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define JUICE_KEYBOARD_MAGIC 0x4a554943u
#define JUICE_KEYBOARD_TEXT 101u
#define JUICE_KEYBOARD_VIRTUAL 102u
#define JUICE_KEYBOARD_HARDWARE 103u
#define JUICE_KEYBOARD_DOWN 1u
#define JUICE_KEYBOARD_UP 2u
#define JUICE_KEYBOARD_EXTENDED 4u
#define JUICE_KEYBOARD_REPEAT 8u

typedef struct
{
    uint32_t magic,type,size;
    uint64_t hwnd;
    int32_t x,y,width,height;
    uint32_t stride,flags;
} JuiceKeyboardMsg;

typedef struct
{
    uint16_t virtualKey,scanCode;
    BOOL extended;
} JuiceKeyboardMap;

static char JuiceKeyboardLogCountKey;

static id JuiceKeyboardValue(id object,NSString *key)
{
    @try{return [object valueForKey:key];}
    @catch(__unused NSException *exception){return nil;}
}

static void JuiceKeyboardAppend(id self,NSString *line)
{
    SEL selector=NSSelectorFromString(@"append:");
    if([self respondsToSelector:selector])
        ((void(*)(id,SEL,id))objc_msgSend)(self,selector,line);
}

static BOOL JuiceKeyboardFDConnected(id self,int fd)
{
    if(fd<0)return NO;
    id clients=JuiceKeyboardValue(self,@"clients");
    if(![clients isKindOfClass:NSArray.class])return YES;
    @synchronized(clients){return [clients containsObject:@(fd)];}
}

/* Resolve the client from the selected HWND rather than relying only on the
 * controller's last active fd. If the selected HWND is tracked but currently
 * disconnected, return -1 instead of falling through to some unrelated active
 * client whose numeric fd may have been reused. */
static int JuiceKeyboardClientForHWND(id self,uint64_t hwnd)
{
    NSDictionary *windows=JuiceKeyboardValue(self,@"wineWindows");
    if(hwnd&&[windows isKindOfClass:NSDictionary.class])
    {
        id state=windows[@(hwnd)];
        if(state)
        {
            int fd=[JuiceKeyboardValue(state,@"clientFD") intValue];
            return JuiceKeyboardFDConnected(self,fd)?fd:-1;
        }
    }
    int active=[JuiceKeyboardValue(self,@"activeClient") intValue];
    return JuiceKeyboardFDConnected(self,active)?active:-1;
}

static BOOL JuiceKeyboardSend(id self,JuiceKeyboardMsg *message,NSData *payload,int fd)
{
    SEL selector=NSSelectorFromString(@"sendMessage:payload:toFD:");
    if(![self respondsToSelector:selector])return NO;
    return ((BOOL(*)(id,SEL,JuiceKeyboardMsg *,id,int))objc_msgSend)
        (self,selector,message,payload,fd);
}

static BOOL JuiceKeyboardRoute(id self,JuiceKeyboardMsg *message,NSData *payload,
                               NSString *kind,int *fdOut)
{
    id canvas=JuiceKeyboardValue(self,@"canvas");
    uint64_t hwnd=[JuiceKeyboardValue(canvas,@"hwnd") unsignedLongLongValue];
    int fd=JuiceKeyboardClientForHWND(self,hwnd);
    if(fdOut)*fdOut=fd;
    if(!hwnd||fd<0)
    {
        JuiceKeyboardAppend(self,[NSString stringWithFormat:
            @"GUI_KEY_REJECTED reason=no-selected-client kind=%@ hwnd=0x%llx fd=%d\n",
            kind?:@"unknown",(unsigned long long)hwnd,fd]);
        return NO;
    }
    message->hwnd=hwnd;
    return JuiceKeyboardSend(self,message,payload,fd);
}

static BOOL JuiceKeyboardShouldLog(id self)
{
    NSUInteger count=[objc_getAssociatedObject(self,&JuiceKeyboardLogCountKey) unsignedIntegerValue];
    objc_setAssociatedObject(self,&JuiceKeyboardLogCountKey,@(count+1),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return count<16;
}

static void JuiceRoutedHardwareKey(id self,SEL _cmd,JuiceKeyboardMap key,
                                   BOOL down,BOOL repeat,NSString *fallback)
{
    (void)_cmd;
    if(!key.scanCode&&down&&fallback.length)
    {
        NSData *payload=[fallback dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
        JuiceKeyboardMsg message={JUICE_KEYBOARD_MAGIC,JUICE_KEYBOARD_TEXT,0,0,0,0,0,0,0,0};
        int fd=-1;BOOL delivered=payload.length&&JuiceKeyboardRoute(self,&message,payload,@"text-fallback",&fd);
        if(JuiceKeyboardShouldLog(self))
            JuiceKeyboardAppend(self,[NSString stringWithFormat:
                @"HARDWARE_KEY_TEXT_FALLBACK fd=%d utf16_units=%lu delivered=%d selected_only=1\n",
                fd,(unsigned long)(payload.length/2),delivered]);
        return;
    }
    if(!key.scanCode)return;

    uint32_t flags=down?JUICE_KEYBOARD_DOWN:JUICE_KEYBOARD_UP;
    if(key.extended)flags|=JUICE_KEYBOARD_EXTENDED;
    if(repeat)flags|=JUICE_KEYBOARD_REPEAT;
    JuiceKeyboardMsg message={JUICE_KEYBOARD_MAGIC,JUICE_KEYBOARD_HARDWARE,0,0,
                              key.virtualKey,key.scanCode,0,0,0,flags};
    int fd=-1;BOOL delivered=JuiceKeyboardRoute(self,&message,nil,@"hardware",&fd);
    if(JuiceKeyboardShouldLog(self))
        JuiceKeyboardAppend(self,[NSString stringWithFormat:
            @"HARDWARE_KEY_SENT hwnd=0x%llx fd=%d vk=0x%x scan=0x%x down=%d extended=%d delivered=%d selected_only=1\n",
            (unsigned long long)message.hwnd,fd,key.virtualKey,key.scanCode,
            down,key.extended,delivered]);
}

static void JuiceRoutedVirtualKey(id self,SEL _cmd,uint32_t key,NSString *name)
{
    (void)_cmd;
    JuiceKeyboardMsg message={JUICE_KEYBOARD_MAGIC,JUICE_KEYBOARD_VIRTUAL,0,0,
                              0,0,0,0,0,key};
    int fd=-1;BOOL delivered=JuiceKeyboardRoute(self,&message,nil,@"virtual",&fd);
    if(message.hwnd)
        JuiceKeyboardAppend(self,[NSString stringWithFormat:
            @"GUI_KEY_SENT hwnd=0x%llx fd=%d key=%@ vk=0x%x delivered=%d selected_only=1\n",
            (unsigned long long)message.hwnd,fd,name?:@"unknown",key,delivered]);
}

__attribute__((constructor(390)))
static void JuiceInstallKeyboardRoutingHardening(void)
{
    Class cls=NSClassFromString(@"JuiceController");
    if(!cls)return;
    Method hardware=class_getInstanceMethod(cls,NSSelectorFromString(@"sendHardwareKey:down:repeat:fallback:"));
    if(hardware)method_setImplementation(hardware,(IMP)JuiceRoutedHardwareKey);
    Method virtualKey=class_getInstanceMethod(cls,NSSelectorFromString(@"sendVirtualKey:name:"));
    if(virtualKey)method_setImplementation(virtualKey,(IMP)JuiceRoutedVirtualKey);
}
