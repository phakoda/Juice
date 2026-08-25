#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define JUICE_POINTER_MAGIC 0x4a554943u
#define JUICE_POINTER_INPUT 100u
#define JUICE_POINTER_LEFT_DOWN 1u
#define JUICE_POINTER_LEFT_UP 2u
#define JUICE_POINTER_WHEEL 0x10u
#define JUICE_POINTER_HWHEEL 0x20u

typedef struct
{
    uint32_t magic,type,size;
    uint64_t hwnd;
    int32_t x,y,width,height;
    uint32_t stride,flags;
} JuicePointerMsg;

static void (*JuicePointerOriginalViewDidLoad)(id,SEL);
static void (*JuicePointerOriginalCanvasSend)(id,SEL,UITouch *,uint32_t);
static char JuicePointerSecondaryDownKey;
static char JuicePointerInstalledKey;

static id JuicePointerValue(id object,NSString *key){@try{return [object valueForKey:key];}@catch(__unused NSException *e){return nil;}}
static void JuicePointerAppend(id self,NSString *line){SEL s=NSSelectorFromString(@"append:");if([self respondsToSelector:s])((void(*)(id,SEL,id))objc_msgSend)(self,s,line);}
static CGPoint JuicePointerWinePoint(UIImageView *canvas,CGPoint point)
{
    CGSize image=canvas.image.size;
    if(image.width<=0||image.height<=0||canvas.bounds.size.width<=0||canvas.bounds.size.height<=0)return point;
    CGFloat scale=MIN(canvas.bounds.size.width/image.width,canvas.bounds.size.height/image.height);
    if(scale<=0||!isfinite(scale))return point;
    CGFloat ox=(canvas.bounds.size.width-image.width*scale)/2.0;
    CGFloat oy=(canvas.bounds.size.height-image.height*scale)/2.0;
    CGFloat x=(point.x-ox)/scale,y=(point.y-oy)/scale;
    return CGPointMake(MAX(0,MIN(image.width-1,x)),MAX(0,MIN(image.height-1,y)));
}
static void JuicePointerDispatch(id self,UIImageView *canvas,CGPoint point,uint32_t flags,int32_t horizontal,int32_t vertical)
{
    uint64_t hwnd=[JuicePointerValue(canvas,@"hwnd") unsignedLongLongValue];if(!hwnd)return;
    CGPoint p=JuicePointerWinePoint(canvas,point);
    JuicePointerMsg message={JUICE_POINTER_MAGIC,JUICE_POINTER_INPUT,0,hwnd,(int32_t)p.x,(int32_t)p.y,horizontal,vertical,0,flags};
    SEL s=NSSelectorFromString(@"handleCanvasInput:");if([self respondsToSelector:s])((void(*)(id,SEL,JuicePointerMsg))objc_msgSend)(self,s,message);
}
static void JuicePointerHover(id self,SEL _cmd,UIHoverGestureRecognizer *hover)
{
    (void)_cmd;if(hover.state!=UIGestureRecognizerStateBegan&&hover.state!=UIGestureRecognizerStateChanged)return;
    UIImageView *canvas=JuicePointerValue(self,@"canvas");if(![canvas isKindOfClass:UIImageView.class]||!canvas.image)return;
    JuicePointerDispatch(self,canvas,[hover locationInView:canvas],0,0,0);
}
static int32_t JuiceWheelDelta(CGFloat points)
{
    long delta=lrint(points*10.0);if(delta>1200)delta=1200;if(delta< -1200)delta=-1200;return (int32_t)delta;
}
static void JuicePointerScroll(id self,SEL _cmd,UIPanGestureRecognizer *scroll)
{
    (void)_cmd;if(scroll.state!=UIGestureRecognizerStateBegan&&scroll.state!=UIGestureRecognizerStateChanged)return;
    UIImageView *canvas=JuicePointerValue(self,@"canvas");if(![canvas isKindOfClass:UIImageView.class]||!canvas.image)return;
    CGPoint translation=[scroll translationInView:canvas];[scroll setTranslation:CGPointZero inView:canvas];
    int32_t vertical=JuiceWheelDelta(-translation.y),horizontal=JuiceWheelDelta(translation.x);CGPoint point=[scroll locationInView:canvas];
    if(vertical)JuicePointerDispatch(self,canvas,point,JUICE_POINTER_WHEEL,0,vertical);
    if(horizontal)JuicePointerDispatch(self,canvas,point,JUICE_POINTER_HWHEEL,horizontal,0);
}
static void JuicePointerCanvasSend(id self,SEL _cmd,UITouch *touch,uint32_t flags)
{
    if(!JuicePointerOriginalCanvasSend)return;
    BOOL secondary=[objc_getAssociatedObject(self,&JuicePointerSecondaryDownKey) boolValue];
    BOOL down=(flags&JUICE_POINTER_LEFT_DOWN)!=0,up=(flags&JUICE_POINTER_LEFT_UP)!=0;
    if(@available(iOS 13.4,*))
    {
        if(down&&touch.type==UITouchTypeIndirectPointer)
        {
            secondary=(touch.buttonMask&UIEventButtonMaskSecondary)!=0;
            objc_setAssociatedObject(self,&JuicePointerSecondaryDownKey,@(secondary),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    BOOL old=[JuicePointerValue(self,@"rightClick") boolValue];
    if(secondary)@try{[self setValue:@YES forKey:@"rightClick"];}@catch(__unused NSException *e){}
    JuicePointerOriginalCanvasSend(self,_cmd,touch,flags);
    if(secondary)@try{[self setValue:@(old) forKey:@"rightClick"];}@catch(__unused NSException *e){}
    if(up)objc_setAssociatedObject(self,&JuicePointerSecondaryDownKey,@NO,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void JuicePointerViewDidLoad(id self,SEL _cmd)
{
    if(JuicePointerOriginalViewDidLoad)JuicePointerOriginalViewDidLoad(self,_cmd);
    if(@available(iOS 13.4,*))
    {
        if([objc_getAssociatedObject(self,&JuicePointerInstalledKey) boolValue])return;
        UIView *canvas=JuicePointerValue(self,@"canvas");if(![canvas isKindOfClass:UIView.class])return;
        UIHoverGestureRecognizer *hover=[[UIHoverGestureRecognizer alloc]initWithTarget:self action:NSSelectorFromString(@"juice_pointerHover:")];hover.cancelsTouchesInView=NO;[canvas addGestureRecognizer:hover];
        UIPanGestureRecognizer *scroll=[[UIPanGestureRecognizer alloc]initWithTarget:self action:NSSelectorFromString(@"juice_pointerScroll:")];
        scroll.allowedScrollTypesMask=UIScrollTypeMaskAll;scroll.allowedTouchTypes=@[];scroll.cancelsTouchesInView=NO;[canvas addGestureRecognizer:scroll];
        objc_setAssociatedObject(self,&JuicePointerInstalledKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        JuicePointerAppend(self,@"POINTER_INPUT_READY hover=1 physical_secondary_click=1 wheel=1 hwheel=1\n");
    }
}

__attribute__((constructor(380)))
static void JuiceInstallPointerInput(void)
{
    Class controller=NSClassFromString(@"JuiceController"),canvas=NSClassFromString(@"WineCanvas");
    if(controller)
    {
        class_addMethod(controller,NSSelectorFromString(@"juice_pointerHover:"),(IMP)JuicePointerHover,"v@:@");
        class_addMethod(controller,NSSelectorFromString(@"juice_pointerScroll:"),(IMP)JuicePointerScroll,"v@:@");
        Method view=class_getInstanceMethod(controller,@selector(viewDidLoad));if(view)JuicePointerOriginalViewDidLoad=(void(*)(id,SEL))method_setImplementation(view,(IMP)JuicePointerViewDidLoad);
    }
    if(canvas)
    {
        Method send=class_getInstanceMethod(canvas,NSSelectorFromString(@"send:flags:"));if(send)JuicePointerOriginalCanvasSend=(void(*)(id,SEL,UITouch *,uint32_t))method_setImplementation(send,(IMP)JuicePointerCanvasSend);
    }
}
