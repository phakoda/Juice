#import "JuiceMetalCompositor.h"
#import "JuiceMetalCore.h"
#import <QuartzCore/CAMetalLayer.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

static char PixelBackingKey, PresenterKey;
static void (*OriginalCanvasLayout)(id, SEL);
static CGPoint (*OriginalWinePoint)(id, SEL, UITouch *);
static void (*OriginalMultiWindowToggle)(id, SEL, BOOL);

@interface JuicePixelBacking : NSObject
@property(nonatomic, strong) NSData *data;
@property(nonatomic) int width, height;
@property(nonatomic) uint32_t stride;
@end
@implementation JuicePixelBacking
@end
@implementation JuiceCompositeWindow
@end

void JuiceAttachPixelBacking(UIImage *image, NSData *data, int width, int height, uint32_t stride)
{
    if (!image || !JuicePixelLayoutValid(width, height, stride, data.length, NULL)) return;
    JuicePixelBacking *backing = [JuicePixelBacking new];
    backing.data = data; backing.width = width; backing.height = height; backing.stride = stride;
    objc_setAssociatedObject(image, &PixelBackingKey, backing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@interface JuiceMetalView : UIView
@end
@implementation JuiceMetalView
+ (Class)layerClass { return CAMetalLayer.class; }
@end

@interface JuiceMetalScene : NSObject
@property(nonatomic, copy) NSArray<JuiceMetalLayer *> *layers;
@property(nonatomic) CGRect viewport;
@end
@implementation JuiceMetalScene
@end

@class JuiceMetalPresenter;
@interface JuiceDisplayTick : NSObject
@property(nonatomic, weak) JuiceMetalPresenter *presenter;
- (void)tick:(CADisplayLink *)link;
@end

@interface JuiceMetalPresenter : NSObject
@property(nonatomic, weak) UIImageView *canvas;
@property(nonatomic, strong) JuiceMetalView *view;
@property(nonatomic, strong) JuiceMetalCore *core;
@property(nonatomic, strong) CADisplayLink *link;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) JuiceMetalScene *pending, *lastScene;
@property(nonatomic, copy) void (^refresh)(void);
@property(nonatomic) BOOL ready, failed, busy, suspended;
@property(nonatomic) uint64_t epoch, requested, replaced, completed, errors, uploads, gpuMicros, gpuSamples;
@property(nonatomic) NSUInteger textureBytes;
- (instancetype)initWithCanvas:(UIImageView *)canvas;
- (void)tick;
- (void)layout;
- (void)hide;
- (void)updatePolicy;
@end
@implementation JuiceDisplayTick
- (void)tick:(CADisplayLink *)link { (void)link; [self.presenter tick]; }
@end

@implementation JuiceMetalPresenter
- (instancetype)initWithCanvas:(UIImageView *)canvas
{
    if (!(self = [super init])) return nil;
    _canvas = canvas;
    _view = [[JuiceMetalView alloc] initWithFrame:canvas.bounds];
    _view.userInteractionEnabled = NO; _view.accessibilityElementsHidden = YES;
    _view.opaque = YES; _view.backgroundColor = UIColor.blackColor; _view.hidden = YES;
    [canvas addSubview:_view];
    _queue = dispatch_queue_create("org.juice.metal-composite", dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    JuiceDisplayTick *tick = [JuiceDisplayTick new]; tick.presenter = self;
    _link = [CADisplayLink displayLinkWithTarget:tick selector:@selector(tick:)];
    _link.paused = YES; [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSString *name in @[UIApplicationWillResignActiveNotification, UIApplicationDidBecomeActiveNotification, UIApplicationDidEnterBackgroundNotification,
                             NSProcessInfoThermalStateDidChangeNotification, NSProcessInfoPowerStateDidChangeNotification,
                             NSUserDefaultsDidChangeNotification])
        [center addObserver:self selector:@selector(policyChanged:) name:name object:nil];
    [center addObserver:self selector:@selector(memoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    /* Shader compilation and command creation never block UIKit's first frame. */
    dispatch_async(_queue, ^{
        NSError *error = nil; JuiceMetalCore *core = [[JuiceMetalCore alloc] initWithError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.core = core; self.ready = core != nil; self.failed = core == nil;
            if (core) {
                CAMetalLayer *layer = (CAMetalLayer *)self.view.layer;
                layer.device = core.device; layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
                layer.framebufferOnly = YES; layer.opaque = YES; layer.maximumDrawableCount = 2;
            } else NSLog(@"METAL_COMPOSITOR_FALLBACK %@", error.localizedDescription);
            if (self.refresh) self.refresh();
        });
    });
    return self;
}
- (void)policyChanged:(NSNotification *)note
{
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self policyChanged:note]; }); return; }
    if ([note.name isEqualToString:UIApplicationWillResignActiveNotification] ||
        [note.name isEqualToString:UIApplicationDidEnterBackgroundNotification]) self.suspended = YES;
    else if ([note.name isEqualToString:UIApplicationDidBecomeActiveNotification]) self.suspended = NO;
    [self updatePolicy];
}
- (void)updatePolicy
{
    NSProcessInfo *process = NSProcessInfo.processInfo;
    unsigned requested = (unsigned)[NSUserDefaults.standardUserDefaults integerForKey:@"JuicePresentationFPS"];
    unsigned maximum = (unsigned)(self.canvas.window.screen ?: UIScreen.mainScreen).maximumFramesPerSecond;
    BOOL active = !self.suspended && UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    unsigned fps = JuicePresentationFPS(requested, maximum, (unsigned)process.thermalState,
                                         process.lowPowerModeEnabled, active);
    JuiceSetSnapshotFPS(fps);
    SEL frameRateSelector = NSSelectorFromString(@"setPreferredFrameRateRange:");
    if ([self.link respondsToSelector:frameRateSelector]) {
        float preferred = fps ?: 15;
        CAFrameRateRange range = CAFrameRateRangeMake(MIN(30, preferred), preferred, preferred);
        ((void (*)(id, SEL, CAFrameRateRange))objc_msgSend)(self.link, frameRateSelector, range);
    } else self.link.preferredFramesPerSecond = fps ?: 15;
    self.link.paused = !fps || self.busy || !self.pending || self.view.hidden || !self.ready || self.failed;
}
- (void)memoryWarning:(NSNotification *)note
{
    (void)note;
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self memoryWarning:nil]; }); return; }
    dispatch_async(self.queue, ^{ [self.core purgeTextures]; });
    self.textureBytes = 0;
    if (!self.view.hidden) self.pending = self.lastScene;
    [self updatePolicy];
}
- (void)layout
{
    if (self.view.hidden || !self.lastScene) return;
    CGSize size = self.lastScene.viewport.size, bounds = self.canvas.bounds.size;
    if (size.width <= 0 || size.height <= 0 || bounds.width <= 0 || bounds.height <= 0) return;
    CGFloat fit = MIN(bounds.width / size.width, bounds.height / size.height);
    CGRect frame = CGRectMake((bounds.width - size.width * fit) / 2,
                              (bounds.height - size.height * fit) / 2, size.width * fit, size.height * fit);
    BOOL changed = !CGRectEqualToRect(frame, self.view.frame);
    self.view.frame = frame;
    CGFloat scale = (self.canvas.window.screen ?: UIScreen.mainScreen).scale;
    double width = MAX(1, ceil(frame.size.width * scale)), height = MAX(1, ceil(frame.size.height * scale));
    double limit = fmin(1, fmin(8192 / fmax(width, height), sqrt((4096.0 * 4096.0) / (width * height))));
    CGSize drawable = CGSizeMake(MAX(1, floor(width * limit)), MAX(1, floor(height * limit)));
    CAMetalLayer *layer = (CAMetalLayer *)self.view.layer;
    if (!CGSizeEqualToSize(layer.drawableSize, drawable)) { layer.drawableSize = drawable; changed = YES; }
    if (changed) self.pending = self.lastScene;
    [self updatePolicy];
}
- (void)hide
{
    self.epoch++; self.pending = nil; self.lastScene = nil;
    self.view.hidden = YES; self.link.paused = YES;
    dispatch_async(self.queue, ^{ [self.core purgeTextures]; });
}
- (void)finishScene:(JuiceMetalScene *)scene epoch:(uint64_t)epoch
             error:(NSError *)error retry:(BOOL)retry uploaded:(uint64_t)uploaded
              size:(NSUInteger)size gpuSeconds:(double)seconds
{
    self.busy = NO;
    if (epoch != self.epoch) { [self updatePolicy]; return; }
    self.uploads = uploaded; self.textureBytes = size;
    if (error) {
        self.errors++; self.failed = YES; [self hide];
        NSLog(@"METAL_COMPOSITOR_FALLBACK %@", error.localizedDescription);
        if (self.refresh) self.refresh();
    } else if (retry) {
        if (!self.pending && !self.view.hidden) self.pending = scene;
    } else {
        self.completed++;
        if (isfinite(seconds) && seconds > 0 && seconds < 60) {
            self.gpuMicros += (uint64_t)(seconds * 1000000); self.gpuSamples++;
        }
    }
    [self updatePolicy];
}
- (void)tick
{
    if (self.busy || !self.pending || !self.ready || self.failed || self.view.hidden ||
        !self.canvas.window || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [self updatePolicy]; return;
    }
    JuiceMetalScene *scene = self.pending; self.pending = nil; self.busy = YES;
    uint64_t epoch = self.epoch;
    BOOL linear = [NSUserDefaults.standardUserDefaults boolForKey:@"JuicePresentationLinear"];
    CAMetalLayer *layer = (CAMetalLayer *)self.view.layer;
    [self updatePolicy];
    dispatch_async(self.queue, ^{ @autoreleasepool {
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (!drawable) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishScene:scene epoch:epoch error:nil retry:YES uploaded:self.uploads
                             size:self.textureBytes gpuSeconds:0];
            });
            return;
        }
        CGRect v = scene.viewport;
        NSError *error = nil;
        id<MTLCommandBuffer> command = [self.core encodeLayers:scene.layers
            viewport:(JuiceRect){v.origin.x, v.origin.y, v.size.width, v.size.height}
            target:drawable.texture linear:linear error:&error];
        uint64_t uploaded = self.core.uploadedBytes; NSUInteger size = self.core.textureBytes;
        if (!command) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishScene:scene epoch:epoch error:error retry:NO uploaded:uploaded size:size gpuSeconds:0];
            });
            return;
        }
        [command presentDrawable:drawable];
        [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            NSError *failure = completed.status == MTLCommandBufferStatusCompleted ? nil :
                (completed.error ?: [NSError errorWithDomain:@"org.juice.metal" code:2 userInfo:nil]);
            double seconds = completed.GPUEndTime - completed.GPUStartTime;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishScene:scene epoch:epoch error:failure retry:NO uploaded:uploaded size:size gpuSeconds:seconds];
            });
        }];
        [command commit];
    }});
}
- (void)dealloc { [_link invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end

BOOL JuicePresentMetalComposite(UIImageView *canvas, NSArray<JuiceCompositeWindow *> *windows,
                                 CGRect viewport, void (^refresh)(void))
{
    NSCAssert(NSThread.isMainThread, @"Metal presentation is owned by UIKit's main queue");
    id enabled = [NSUserDefaults.standardUserDefaults objectForKey:@"JuiceMetalCompositorEnabled"];
    if ((enabled && ![enabled boolValue]) || windows.count > 128) { JuiceHideMetalComposite(canvas); return NO; }
    JuiceMetalPresenter *presenter = objc_getAssociatedObject(canvas, &PresenterKey);
    if (!presenter) {
        presenter = [[JuiceMetalPresenter alloc] initWithCanvas:canvas];
        objc_setAssociatedObject(canvas, &PresenterKey, presenter, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    presenter.refresh = refresh;
    if (!presenter.ready || presenter.failed) return NO;
    NSMutableArray<JuiceMetalLayer *> *layers = [NSMutableArray arrayWithCapacity:windows.count];
    for (JuiceCompositeWindow *window in windows) {
        JuicePixelBacking *backing = objc_getAssociatedObject(window.image, &PixelBackingKey);
        if (!backing) { [presenter hide]; return NO; }
        JuiceMetalLayer *layer = [JuiceMetalLayer new];
        layer.identifier = window.identifier; layer.pixels = backing.data;
        layer.width = backing.width; layer.height = backing.height; layer.stride = backing.stride;
        CGRect r = window.frame;
        layer.frame = (JuiceRect){r.origin.x, r.origin.y, r.size.width, r.size.height};
        [layers addObject:layer];
    }
    JuiceMetalScene *scene = [JuiceMetalScene new]; scene.layers = layers; scene.viewport = viewport;
    presenter.requested++; if (presenter.pending) presenter.replaced++;
    presenter.pending = presenter.lastScene = scene;
    presenter.view.hidden = NO;
    [presenter layout];
    [presenter updatePolicy];
    return YES;
}
void JuiceHideMetalComposite(UIImageView *canvas)
{
    JuiceMetalPresenter *presenter = objc_getAssociatedObject(canvas, &PresenterKey);
    if (presenter && !presenter.view.hidden) [presenter hide];
}
void JuiceResetMetalComposite(UIImageView *canvas)
{
    JuiceMetalPresenter *presenter = objc_getAssociatedObject(canvas, &PresenterKey);
    [presenter hide]; [presenter.view removeFromSuperview];
    objc_setAssociatedObject(canvas, &PresenterKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
CGSize JuiceCanvasContentSize(UIImageView *canvas)
{
    JuiceMetalPresenter *presenter = objc_getAssociatedObject(canvas, &PresenterKey);
    return presenter && !presenter.view.hidden && presenter.lastScene ? presenter.lastScene.viewport.size : canvas.image.size;
}
NSDictionary<NSString *, NSNumber *> *JuiceMetalStatistics(UIImageView *canvas)
{
    JuiceMetalPresenter *p = objc_getAssociatedObject(canvas, &PresenterKey);
    return @{@"ready": @(p.ready), @"failed": @(p.failed), @"active": @(p && !p.view.hidden),
             @"requested": @(p.requested), @"replaced": @(p.replaced), @"completed": @(p.completed),
             @"gpu_errors": @(p.errors), @"texture_bytes": @(p.textureBytes), @"uploaded_bytes": @(p.uploads),
             @"gpu_microseconds": @(p.gpuMicros), @"gpu_samples": @(p.gpuSamples)};
}
static void CanvasLayout(id canvas, SEL selector)
{
    if (OriginalCanvasLayout) OriginalCanvasLayout(canvas, selector);
    [(JuiceMetalPresenter *)objc_getAssociatedObject(canvas, &PresenterKey) layout];
}
static CGPoint CanvasWinePoint(id canvas, SEL selector, UITouch *touch)
{
    CGSize size = JuiceCanvasContentSize(canvas), bounds = [(UIView *)canvas bounds].size;
    CGPoint p = [touch locationInView:canvas]; double x, y;
    if (JuiceAspectFitPoint(bounds.width, bounds.height, size.width, size.height, p.x, p.y, &x, &y))
        return CGPointMake(x, y);
    return OriginalWinePoint ? OriginalWinePoint(canvas, selector, touch) : p;
}
static void ToggleMultiWindow(id owner, SEL selector, BOOL enabled)
{
    if (OriginalMultiWindowToggle) OriginalMultiWindowToggle(owner, selector, enabled);
    if (!enabled) { @try { JuiceHideMetalComposite([owner valueForKey:@"canvas"]); } @catch (__unused NSException *e) {} }
}
__attribute__((constructor(760)))
static void InstallMetalPresentation(void)
{
    Class canvas = NSClassFromString(@"WineCanvas"), owner = NSClassFromString(@"JuiceController");
    if (canvas) {
        Method layout = class_getInstanceMethod(canvas, @selector(layoutSubviews));
        if (layout) {
            OriginalCanvasLayout = (void *)method_getImplementation(layout);
            if (!class_addMethod(canvas, @selector(layoutSubviews), (IMP)CanvasLayout, method_getTypeEncoding(layout)))
                OriginalCanvasLayout = (void *)method_setImplementation(layout, (IMP)CanvasLayout);
        }
        Method point = class_getInstanceMethod(canvas, NSSelectorFromString(@"winePoint:"));
        if (point) OriginalWinePoint = (void *)method_setImplementation(point, (IMP)CanvasWinePoint);
    }
    Method toggle = class_getInstanceMethod(owner, NSSelectorFromString(@"applyExperimentalMultiWindowEnabled:"));
    if (toggle) OriginalMultiWindowToggle = (void *)method_setImplementation(toggle, (IMP)ToggleMultiWindow);
}
