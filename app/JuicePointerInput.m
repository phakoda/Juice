#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define JUICE_POINTER_MAGIC 0x4a554943u
#define JUICE_POINTER_INPUT 100u
#define JUICE_POINTER_LEFT_DOWN 1u
#define JUICE_POINTER_LEFT_UP 2u

typedef struct
{
    uint32_t magic, type, size;
    uint64_t hwnd;
    int32_t x, y, width, height;
    uint32_t stride, flags;
} JuicePointerMsg;

static void (*JuicePointerOriginalViewDidLoad)(id, SEL);
static void (*JuicePointerOriginalCanvasSend)(id, SEL, UITouch *, uint32_t);
static char JuicePointerSecondaryDownKey;
static char JuicePointerHoverInstalledKey;

static id JuicePointerValue(id object, NSString *key)
{
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuicePointerAppend(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static CGPoint JuicePointerWinePoint(UIImageView *canvas, CGPoint point)
{
    CGSize image = canvas.image.size;
    if (image.width <= 0 || image.height <= 0 ||
        canvas.bounds.size.width <= 0 || canvas.bounds.size.height <= 0)
        return point;

    CGFloat scale = MIN(canvas.bounds.size.width / image.width,
                        canvas.bounds.size.height / image.height);
    if (scale <= 0 || !isfinite(scale)) return point;

    CGFloat offsetX = (canvas.bounds.size.width - image.width * scale) / 2.0;
    CGFloat offsetY = (canvas.bounds.size.height - image.height * scale) / 2.0;
    CGFloat x = (point.x - offsetX) / scale;
    CGFloat y = (point.y - offsetY) / scale;
    x = MAX(0.0, MIN(image.width - 1.0, x));
    y = MAX(0.0, MIN(image.height - 1.0, y));
    return CGPointMake(x, y);
}

static void JuicePointerHover(id self, SEL _cmd, UIHoverGestureRecognizer *hover)
{
    (void)_cmd;
    if (hover.state != UIGestureRecognizerStateBegan &&
        hover.state != UIGestureRecognizerStateChanged) return;

    UIImageView *canvas = JuicePointerValue(self, @"canvas");
    if (![canvas isKindOfClass:UIImageView.class] || !canvas.image) return;
    uint64_t hwnd = [JuicePointerValue(canvas, @"hwnd") unsignedLongLongValue];
    if (!hwnd) return;

    CGPoint point = JuicePointerWinePoint(canvas, [hover locationInView:canvas]);
    JuicePointerMsg message = {
        JUICE_POINTER_MAGIC, JUICE_POINTER_INPUT, 0, hwnd,
        (int32_t)point.x, (int32_t)point.y, 0, 0, 0, 0
    };

    SEL input = NSSelectorFromString(@"handleCanvasInput:");
    if ([self respondsToSelector:input])
        ((void (*)(id, SEL, JuicePointerMsg))objc_msgSend)(self, input, message);
}

static void JuicePointerCanvasSend(id self, SEL _cmd, UITouch *touch, uint32_t flags)
{
    if (!JuicePointerOriginalCanvasSend)
        return;

    BOOL secondary = [objc_getAssociatedObject(self, &JuicePointerSecondaryDownKey) boolValue];
    BOOL isDown = (flags & JUICE_POINTER_LEFT_DOWN) != 0;
    BOOL isUp = (flags & JUICE_POINTER_LEFT_UP) != 0;

    if (@available(iOS 13.4, *))
    {
        if (isDown && touch.type == UITouchTypeIndirectPointer)
        {
            secondary = (touch.buttonMask & UIEventButtonMaskSecondary) != 0;
            objc_setAssociatedObject(self, &JuicePointerSecondaryDownKey, @(secondary),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    BOOL oldRight = [JuicePointerValue(self, @"rightClick") boolValue];
    if (secondary)
    {
        @try { [self setValue:@YES forKey:@"rightClick"]; }
        @catch (__unused NSException *exception) {}
    }

    JuicePointerOriginalCanvasSend(self, _cmd, touch, flags);

    if (secondary)
    {
        @try { [self setValue:@(oldRight) forKey:@"rightClick"]; }
        @catch (__unused NSException *exception) {}
    }
    if (isUp)
        objc_setAssociatedObject(self, &JuicePointerSecondaryDownKey, @NO,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void JuicePointerViewDidLoad(id self, SEL _cmd)
{
    if (JuicePointerOriginalViewDidLoad) JuicePointerOriginalViewDidLoad(self, _cmd);
    if (@available(iOS 13.4, *))
    {
        if ([objc_getAssociatedObject(self, &JuicePointerHoverInstalledKey) boolValue]) return;
        UIView *canvas = JuicePointerValue(self, @"canvas");
        if (![canvas isKindOfClass:UIView.class]) return;

        UIHoverGestureRecognizer *hover = [[UIHoverGestureRecognizer alloc]
            initWithTarget:self action:NSSelectorFromString(@"juice_pointerHover:")];
        hover.cancelsTouchesInView = NO;
        [canvas addGestureRecognizer:hover];
        objc_setAssociatedObject(self, &JuicePointerHoverInstalledKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        JuicePointerAppend(self, @"POINTER_INPUT_READY hover=1 physical_secondary_click=1\n");
    }
}

__attribute__((constructor(380)))
static void JuiceInstallPointerInput(void)
{
    Class controller = NSClassFromString(@"JuiceController");
    Class canvas = NSClassFromString(@"WineCanvas");
    if (controller)
    {
        SEL hoverSelector = NSSelectorFromString(@"juice_pointerHover:");
        class_addMethod(controller, hoverSelector, (IMP)JuicePointerHover, "v@:@");

        Method view = class_getInstanceMethod(controller, @selector(viewDidLoad));
        if (view)
            JuicePointerOriginalViewDidLoad = (void (*)(id, SEL))
                method_setImplementation(view, (IMP)JuicePointerViewDidLoad);
    }

    if (canvas)
    {
        SEL sendSelector = NSSelectorFromString(@"send:flags:");
        Method send = class_getInstanceMethod(canvas, sendSelector);
        if (send)
            JuicePointerOriginalCanvasSend = (void (*)(id, SEL, UITouch *, uint32_t))
                method_setImplementation(send, (IMP)JuicePointerCanvasSend);
    }
}
