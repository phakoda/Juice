#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/utsname.h>
#import "JuiceKeyChord.h"
#import "JuiceMetalCompositor.h"
#import "JuicePresentationPolicy.h"

static char ControlsKey;
static void (*OriginalViewDidLoad)(id,SEL), (*OriginalLayout)(id,SEL), (*OriginalMenu)(id,SEL);
static id Value(id owner,NSString *key)
{
    @try { return [owner valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}
static void Invoke(id owner,NSString *name)
{
    SEL selector=NSSelectorFromString(name);
    if([owner respondsToSelector:selector]) ((void(*)(id,SEL))objc_msgSend)(owner,selector);
}
static void Alert(UIViewController *owner,NSString *message)
{
    if(!owner || owner.presentedViewController)return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Windows input" message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [owner presentViewController:alert animated:YES completion:nil];
}

/* Native UITextView owns marked text, candidate selection, dictation and edits.
 * Nothing is transmitted until Send: this avoids leaking unfinished IME text. */
@interface JuiceComposeController : UIViewController <UITextViewDelegate>
@property(nonatomic,weak) id owner;
@property(nonatomic,strong) UITextView *editor;
@end
@implementation JuiceComposeController
- (void)viewDidLoad
{
    [super viewDidLoad]; self.title=@"Compose Windows text";
    self.view.backgroundColor=UIColor.systemBackgroundColor;
    self.editor=[UITextView new]; self.editor.delegate=self;
    self.editor.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.editor.accessibilityIdentifier=@"juice.windows-text-composer";
    self.editor.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:self.editor];
    [NSLayoutConstraint activateConstraints:@[
        [self.editor.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.editor.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [self.editor.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [self.editor.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12]]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardChanged:)
        name:UIKeyboardWillChangeFrameNotification object:nil];
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
        target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Send" style:UIBarButtonItemStyleDone
        target:self action:@selector(send)];
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self.editor becomeFirstResponder]; }
- (BOOL)textView:(UITextView *)view shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text
{
    if(range.location>view.text.length || range.length>view.text.length-range.location)return NO;
    NSUInteger retained=view.text.length-range.length;
    return retained<=65536 && text.length<=65536-retained;
}
- (void)keyboardChanged:(NSNotification *)notification
{
    NSValue *value=notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    if(!value || !self.view.window)return;
    CGRect frame=[self.editor convertRect:value.CGRectValue fromView:nil];
    CGRect overlap=CGRectIntersection(self.editor.bounds,frame);
    CGFloat bottom=CGRectIsNull(overlap)?0:MAX(0,CGRectGetMaxY(self.editor.bounds)-CGRectGetMinY(overlap));
    self.editor.contentInset=UIEdgeInsetsMake(0,0,bottom,0);
    self.editor.scrollIndicatorInsets=self.editor.contentInset;
    [self.editor scrollRangeToVisible:self.editor.selectedRange];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)send
{
    if(self.editor.markedTextRange) { Alert(self,@"Finish selecting the composed text before sending."); return; }
    if(!self.editor.text.length)return;
    if(JuiceSendText(self.owner,self.editor.text,@"native-composer")) [self cancel];
    else Alert(self,@"Text was not fully queued. Check the selected Windows window and connection before retrying.");
}
@end

@interface JuiceLiveKeyboard : UIView <UIKeyInput,UITextInputTraits>
@property(nonatomic,weak) UIViewController *owner;
@property(nonatomic,strong) UIView *toolbar;
@property(nonatomic,strong) NSMutableArray<UIButton *> *modifierButtons;
@property(nonatomic) unsigned modifiers;
@property(nonatomic) UITextAutocapitalizationType autocapitalizationType;
@property(nonatomic) UITextAutocorrectionType autocorrectionType;
@property(nonatomic) UITextSpellCheckingType spellCheckingType;
@property(nonatomic) UIKeyboardType keyboardType;
@property(nonatomic) UIKeyboardAppearance keyboardAppearance;
@property(nonatomic) UIReturnKeyType returnKeyType;
@property(nonatomic) BOOL enablesReturnKeyAutomatically;
@property(nonatomic,getter=isSecureTextEntry) BOOL secureTextEntry;
- (void)key:(uint16_t)key scan:(uint16_t)scan extended:(BOOL)extended modifiers:(unsigned)modifiers;
@end
@implementation JuiceLiveKeyboard
- (BOOL)canBecomeFirstResponder { return self.window!=nil; }
- (BOOL)hasText { return YES; } /* Backspace must reach Windows, not an empty host buffer. */
- (UIView *)inputAccessoryView { return self.toolbar; }
- (void)setModifiers:(unsigned)modifiers
{
    _modifiers=modifiers&15u;
    for(UIButton *button in self.modifierButtons) button.selected=(_modifiers & (unsigned)button.tag)!=0;
}
- (BOOL)resignFirstResponder { self.modifiers=0; return [super resignFirstResponder]; }
- (void)key:(uint16_t)key scan:(uint16_t)scan extended:(BOOL)extended modifiers:(unsigned)modifiers
{
    self.modifiers=0;
    if(!JuiceQueueKeyChord(self.owner,key,scan,extended,modifiers))
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"No selected Windows input connection");
}
- (void)deleteBackward { [self key:0x08 scan:0x0e extended:NO modifiers:self.modifiers]; }
- (void)insertText:(NSString *)text
{
    if(!text.length || text.length>65536)return;
    unsigned modifiers=self.modifiers; self.modifiers=0;
    if(modifiers) {
        static const uint8_t scans[26]={0x1e,0x30,0x2e,0x20,0x12,0x21,0x22,0x23,0x17,0x24,0x25,0x26,0x32,
                                       0x31,0x18,0x19,0x10,0x13,0x1f,0x14,0x16,0x2f,0x11,0x2d,0x15,0x2c};
        unichar c=text.length==1?[text characterAtIndex:0]:0;
        if(c>='a' && c<='z') { [self key:c-32 scan:scans[c-'a'] extended:NO modifiers:modifiers]; return; }
        if(c>='A' && c<='Z') { [self key:c scan:scans[c-'A'] extended:NO modifiers:modifiers|JUICE_CHORD_SHIFT]; return; }
        if(c>='0' && c<='9') { [self key:c scan:c=='0'?0x0b:(uint16_t)(2+c-'1') extended:NO modifiers:modifiers]; return; }
        if(c==' ') { [self key:0x20 scan:0x39 extended:NO modifiers:modifiers]; return; }
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"A modifier shortcut needs one letter, digit, or space");
        return;
    }
    NSUInteger start=0;
    for(NSUInteger i=0;i<text.length;i++) {
        unichar c=[text characterAtIndex:i];
        if(c!='\n' && c!='\r' && c!='\t')continue;
        if(i>start && !JuiceSendText(self.owner,[text substringWithRange:NSMakeRange(start,i-start)],@"live-keyboard"))return;
        if(!JuiceQueueKeyChord(self.owner,c=='\t'?0x09:0x0d,c=='\t'?0x0f:0x1c,NO,0))return;
        if(c=='\r' && i+1<text.length && [text characterAtIndex:i+1]=='\n')i++;
        start=i+1;
    }
    if(start<text.length) JuiceSendText(self.owner,[text substringFromIndex:start],@"live-keyboard");
}
@end

@interface JuiceDesktopControls : NSObject
@property(nonatomic,weak) UIViewController *owner;
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,strong) UILabel *hud;
@property(nonatomic,strong) JuiceLiveKeyboard *keyboard;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic) BOOL suspended;
@property(nonatomic) CFTimeInterval previousTime;
@property(nonatomic) uint64_t previousFrames,previousUploads;
- (instancetype)initWithOwner:(UIViewController *)owner;
- (UIMenu *)menu;
- (void)layout;
- (void)refreshPolicy;
@end
@implementation JuiceDesktopControls
- (instancetype)initWithOwner:(UIViewController *)owner
{
    if(!(self=[super init]))return nil;
    _owner=owner;
    _button=[UIButton buttonWithType:UIButtonTypeSystem];
    [_button setTitle:@"Controls" forState:UIControlStateNormal];
    _button.accessibilityIdentifier=@"juice.desktop-controls";
    _button.backgroundColor=[UIColor colorWithWhite:0 alpha:.7]; _button.tintColor=UIColor.whiteColor;
    _button.layer.cornerRadius=8; _button.showsMenuAsPrimaryAction=YES;
    [owner.view addSubview:_button];
    _hud=[UILabel new]; _hud.numberOfLines=3;
    _hud.font=[UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    _hud.textColor=UIColor.whiteColor; _hud.backgroundColor=[UIColor colorWithWhite:0 alpha:.75];
    _hud.userInteractionEnabled=NO; _hud.accessibilityIdentifier=@"juice.host-renderer-hud";
    [owner.view addSubview:_hud];
    _keyboard=[[JuiceLiveKeyboard alloc] initWithFrame:CGRectMake(0,0,1,1)];
    _keyboard.owner=owner; _keyboard.accessibilityElementsHidden=YES;
    _keyboard.autocapitalizationType=UITextAutocapitalizationTypeNone;
    _keyboard.autocorrectionType=UITextAutocorrectionTypeNo;
    _keyboard.spellCheckingType=UITextSpellCheckingTypeNo;
    _keyboard.userInteractionEnabled=NO;
    [owner.view addSubview:_keyboard]; [self buildKeyboardToolbar];
    for(NSString *name in @[UIApplicationWillResignActiveNotification, UIApplicationDidBecomeActiveNotification,
            UIApplicationDidEnterBackgroundNotification, NSProcessInfoThermalStateDidChangeNotification,
            NSProcessInfoPowerStateDidChangeNotification, NSUserDefaultsDidChangeNotification])
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed:) name:name object:nil];
    _button.menu=[self menu]; [self layout];
    return self;
}
- (void)buildKeyboardToolbar
{
    UIScrollView *scroll=[[UIScrollView alloc] initWithFrame:CGRectMake(0,0,320,50)];
    scroll.backgroundColor=UIColor.secondarySystemBackgroundColor;
    scroll.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    UIStackView *stack=[UIStackView new]; stack.spacing=4; stack.translatesAutoresizingMaskIntoConstraints=NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:4],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-4],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:3],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-3],
        [stack.heightAnchor constraintEqualToConstant:44]]];
    self.keyboard.modifierButtons=[NSMutableArray array];
    NSArray *names=@[@"Done",@"Ctrl",@"Alt",@"Shift",@"Win",@"Esc",@"Tab",@"←",@"↑",@"↓",@"→"];
    __weak JuiceDesktopControls *weakSelf=self;
    for(NSUInteger i=0;i<names.count;i++) {
        UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem]; [b setTitle:names[i] forState:UIControlStateNormal];
        [b.widthAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
        if(i>=1 && i<=4) {
            b.tag=1<<(i-1); [b setTitle:[names[i] stringByAppendingString:@" ✓"] forState:UIControlStateSelected];
            [self.keyboard.modifierButtons addObject:b];
        }
        [b addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            JuiceDesktopControls *s=weakSelf; if(!s)return;
            if(i==0) { [s.keyboard resignFirstResponder]; return; }
            if(i<=4) { s.keyboard.modifiers^=(1u<<(i-1)); return; }
            static const uint16_t keys[]={0x1b,0x09,0x25,0x26,0x28,0x27};
            static const uint16_t scans[]={0x01,0x0f,0x4b,0x48,0x50,0x4d};
            [s.keyboard key:keys[i-5] scan:scans[i-5] extended:i>=7 modifiers:s.keyboard.modifiers];
        }] forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:b];
    }
    self.keyboard.toolbar=scroll;
}
- (void)changed:(NSNotification *)notification
{
    if(!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{[self changed:notification];}); return; }
    if([notification.name isEqualToString:UIApplicationWillResignActiveNotification] ||
       [notification.name isEqualToString:UIApplicationDidEnterBackgroundNotification]) {
        self.suspended=YES; [self.keyboard resignFirstResponder];
    } else if([notification.name isEqualToString:UIApplicationDidBecomeActiveNotification])self.suspended=NO;
    self.button.menu=[self menu]; [self refreshPolicy];
}
- (void)refreshPolicy
{
    NSProcessInfo *process=NSProcessInfo.processInfo;
    BOOL active=!self.suspended && self.owner.view.window && UIApplication.sharedApplication.applicationState==UIApplicationStateActive;
    UIScreen *screen=self.owner.view.window.screen?:UIScreen.mainScreen;
    unsigned fps=JuicePresentationFPS((unsigned)[NSUserDefaults.standardUserDefaults integerForKey:@"JuicePresentationFPS"],
        (unsigned)screen.maximumFramesPerSecond,(unsigned)process.thermalState,process.lowPowerModeEnabled,active);
    JuiceSetSnapshotFPS(fps);
    self.hud.hidden=![NSUserDefaults.standardUserDefaults boolForKey:@"JuicePerformanceHUD"] || !active;
    if(self.hud.hidden) { [self.timer invalidate]; self.timer=nil; self.previousTime=0; return; }
    if(!self.timer) {
        __weak JuiceDesktopControls *weakSelf=self;
        self.timer=[NSTimer timerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer){[weakSelf sample];}];
        self.timer.tolerance=.25;
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
        [self sample];
    }
}
- (void)sample
{
    NSDictionary *stats=JuiceMetalStatistics(Value(self.owner,@"canvas"));
    CFTimeInterval now=CACurrentMediaTime(), interval=self.previousTime?now-self.previousTime:0;
    uint64_t frames=[stats[@"completed"] unsignedLongLongValue], uploads=[stats[@"uploaded_bytes"] unsignedLongLongValue];
    double rate=interval>0 && frames>=self.previousFrames?(frames-self.previousFrames)/interval:0;
    double bandwidth=interval>0 && uploads>=self.previousUploads?(uploads-self.previousUploads)/interval/1048576.0:0;
    uint64_t samples=[stats[@"gpu_samples"] unsignedLongLongValue];
    double gpu=samples?[stats[@"gpu_microseconds"] doubleValue]/samples/1000.0:0;
    self.previousTime=now; self.previousFrames=frames; self.previousUploads=uploads;
    NSArray *thermal=@[@"nominal",@"fair",@"serious",@"critical"];
    NSUInteger state=MIN((NSUInteger)NSProcessInfo.processInfo.thermalState,3u);
    self.hud.text=[NSString stringWithFormat:@" Host %@: %.1f submissions/s (not game FPS)\n GPU %.2f ms avg · textures %.1f MiB · upload %.1f MiB/s\n Cap %u · thermal %@ · coalesced %@",
        [stats[@"active"] boolValue]?@"Metal":@"CPU/fallback",rate,gpu,[stats[@"texture_bytes"] doubleValue]/1048576.0,
        bandwidth,JuiceGetSnapshotFPS(),thermal[state],stats[@"replaced"]];
}
- (void)layout
{
    UIView *view=self.owner.view; UIEdgeInsets safe=view.safeAreaInsets;
    self.button.frame=CGRectMake(MAX(safe.left+8,view.bounds.size.width-safe.right-100),safe.top+50,92,38);
    self.hud.frame=CGRectMake(safe.left+8,safe.top+50,MAX(1,MIN(350,view.bounds.size.width-safe.left-safe.right-120)),58);
    [view bringSubviewToFront:self.button]; [view bringSubviewToFront:self.hud]; [self refreshPolicy];
}
- (void)rebuild
{
    self.button.menu=[self menu]; Invoke(self.owner,@"rebuildExperimentalMenu");
    Invoke(self.owner,@"compositeWineDesktop"); [self refreshPolicy];
}
- (void)shareReport
{
    if(self.owner.presentedViewController)return;
    struct utsname hardware={0}; uname(&hardware);
    NSProcessInfo *process=NSProcessInfo.processInfo;
    NSDictionary *report=@{@"schema_version":@1,@"kind":@"juice-host-presentation-diagnostic",
        @"timestamp":[NSISO8601DateFormatter.new stringFromDate:NSDate.date],
        @"device":[NSString stringWithUTF8String:hardware.machine]?:@"unknown",
        @"os":process.operatingSystemVersionString,@"active_processor_count":@(process.activeProcessorCount),
        @"physical_memory_bytes":@(process.physicalMemory),@"thermal_state":@(process.thermalState),
        @"low_power":@(process.lowPowerModeEnabled),@"snapshot_cap":@(JuiceGetSnapshotFPS()),
        @"app_version":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"unknown",
        @"renderer":JuiceMetalStatistics(Value(self.owner,@"canvas")),
        @"scope":@"Host presentation only. Not guest FPS, CPU usage, universal compatibility, or a benchmark."};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
    if(!json)return;
    UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:
        @[[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]] applicationActivities:nil];
    share.popoverPresentationController.sourceView=self.button;
    share.popoverPresentationController.sourceRect=self.button.bounds;
    [self.owner presentViewController:share animated:YES completion:nil];
}
- (UIMenu *)menu
{
    __weak JuiceDesktopControls *weakSelf=self;
    NSMutableArray<UIMenuElement *> *items=[NSMutableArray array];
    [items addObject:[UIAction actionWithTitle:@"Live keyboard" image:nil identifier:nil handler:^(__unused UIAction *a){
        JuiceDesktopControls *s=weakSelf; if(!s || s.owner.presentedViewController)return;
        [s.keyboard becomeFirstResponder];
    }]];
    [items addObject:[UIAction actionWithTitle:@"Compose text / IME…" image:nil identifier:nil handler:^(__unused UIAction *a){
        JuiceDesktopControls *s=weakSelf; if(!s || s.owner.presentedViewController)return;
        [s.keyboard resignFirstResponder]; JuiceComposeController *composer=[JuiceComposeController new]; composer.owner=s.owner;
        UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:composer];
        nav.modalPresentationStyle=UIModalPresentationFormSheet;
        [s.owner presentViewController:nav animated:YES completion:nil];
    }]];
    [items addObject:[UIAction actionWithTitle:@"Paste iOS clipboard" image:nil identifier:nil handler:^(__unused UIAction *a){
        JuiceDesktopControls *s=weakSelf; SEL paste=NSSelectorFromString(@"juice_pasteIOSClipboard:");
        if([s.owner respondsToSelector:paste])((void(*)(id,SEL,id))objc_msgSend)(s.owner,paste,nil);
    }]];
    NSMutableArray *shortcuts=[NSMutableArray array];
    NSArray *specs=@[@[@"Escape",@0x1b,@1,@0,@0],@[@"Tab",@9,@0x0f,@0,@0],@[@"Enter",@13,@0x1c,@0,@0],
        @[@"Copy (Ctrl+C)",@0x43,@0x2e,@0,@1],@[@"Cut (Ctrl+X)",@0x58,@0x2d,@0,@1],
        @[@"Paste Windows clipboard (Ctrl+V)",@0x56,@0x2f,@0,@1],@[@"Select all (Ctrl+A)",@0x41,@0x1e,@0,@1],
        @[@"Undo (Ctrl+Z)",@0x5a,@0x2c,@0,@1],@[@"Redo (Ctrl+Y)",@0x59,@0x15,@0,@1],
        @[@"Switch window (Alt+Tab)",@9,@0x0f,@0,@2],@[@"Close window (Alt+F4)",@0x73,@0x3e,@0,@2],
        @[@"Home",@0x24,@0x47,@1,@0],@[@"End",@0x23,@0x4f,@1,@0],
        @[@"Page Up",@0x21,@0x49,@1,@0],@[@"Page Down",@0x22,@0x51,@1,@0],@[@"Delete",@0x2e,@0x53,@1,@0]];
    for(NSArray *spec in specs) [shortcuts addObject:[UIAction actionWithTitle:spec[0] image:nil identifier:nil handler:^(__unused UIAction *a){
        [weakSelf.keyboard key:[spec[1] unsignedShortValue] scan:[spec[2] unsignedShortValue]
            extended:[spec[3] boolValue] modifiers:[spec[4] unsignedIntValue]];
    }]];
    NSMutableArray *functions=[NSMutableArray array];
    for(unsigned i=0;i<12;i++) [functions addObject:[UIAction actionWithTitle:[NSString stringWithFormat:@"F%u",i+1]
        image:nil identifier:nil handler:^(__unused UIAction *a){
            [weakSelf.keyboard key:0x70+i scan:i<10?0x3b+i:(i==10?0x57:0x58) extended:NO modifiers:0];
        }]];
    [shortcuts addObject:[UIMenu menuWithTitle:@"Function keys" children:functions]];
    [items addObject:[UIMenu menuWithTitle:@"Windows shortcuts" children:shortcuts]];
    NSMutableArray *presentation=[NSMutableArray array];
    for(NSArray *spec in @[@[@"Metal multi-window compositor",@"JuiceMetalCompositorEnabled"],
                           @[@"Smooth scaling",@"JuicePresentationLinear"],@[@"Host rendering HUD",@"JuicePerformanceHUD"]]) {
        NSString *key=spec[1]; id stored=[NSUserDefaults.standardUserDefaults objectForKey:key];
        BOOL on=stored?[stored boolValue]:[key isEqualToString:@"JuiceMetalCompositorEnabled"];
        UIAction *toggle=[UIAction actionWithTitle:spec[0] image:nil identifier:nil handler:^(__unused UIAction *a){
            JuiceDesktopControls *s=weakSelf; if(!s)return;
            [NSUserDefaults.standardUserDefaults setBool:!on forKey:key]; [s rebuild];
        }]; toggle.state=on?UIMenuElementStateOn:UIMenuElementStateOff; [presentation addObject:toggle];
    }
    NSMutableArray *rates=[NSMutableArray array];
    for(NSNumber *rate in @[@0,@15,@30,@60,@120]) {
        UIAction *action=[UIAction actionWithTitle:rate.unsignedIntValue?[NSString stringWithFormat:@"%@ FPS cap",rate]:@"Automatic (up to 120)"
            image:nil identifier:nil handler:^(__unused UIAction *a){
                [NSUserDefaults.standardUserDefaults setInteger:rate.integerValue forKey:@"JuicePresentationFPS"];
                [weakSelf rebuild];
            }];
        action.state=[NSUserDefaults.standardUserDefaults integerForKey:@"JuicePresentationFPS"]==rate.integerValue?
            UIMenuElementStateOn:UIMenuElementStateOff;
        [rates addObject:action];
    }
    [presentation addObject:[UIMenu menuWithTitle:@"Presentation cap" children:rates]];
    [presentation addObject:[UIAction actionWithTitle:@"Reset Metal renderer" image:nil identifier:nil handler:^(__unused UIAction *a){
        JuiceDesktopControls *s=weakSelf; if(!s)return;
        JuiceResetMetalComposite(Value(s.owner,@"canvas")); [s rebuild];
    }]];
    [items addObject:[UIMenu menuWithTitle:@"Presentation and power" children:presentation]];
    [items addObject:[UIAction actionWithTitle:@"Share host rendering report…" image:nil identifier:nil handler:^(__unused UIAction *a){[weakSelf shareReport];}]];
    return [UIMenu menuWithTitle:@"Desktop controls" children:items];
}
- (void)dealloc { [_timer invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
static void ViewDidLoad(id owner,SEL selector)
{
    if(OriginalViewDidLoad)OriginalViewDidLoad(owner,selector);
    JuiceDesktopControls *controls=[[JuiceDesktopControls alloc] initWithOwner:owner];
    objc_setAssociatedObject(owner,&ControlsKey,controls,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    Invoke(owner,@"rebuildExperimentalMenu");
}
static void Layout(id owner,SEL selector)
{
    if(OriginalLayout)OriginalLayout(owner,selector);
    [(JuiceDesktopControls *)objc_getAssociatedObject(owner,&ControlsKey) layout];
}
static void Menu(id owner,SEL selector)
{
    if(OriginalMenu)OriginalMenu(owner,selector);
    JuiceDesktopControls *controls=objc_getAssociatedObject(owner,&ControlsKey);
    UIButton *button=Value(owner,@"experimentalButton");
    if(!controls || !button.menu)return;
    NSMutableArray *children=[button.menu.children mutableCopy]; [children addObject:[controls menu]];
    button.menu=[UIMenu menuWithTitle:button.menu.title children:children];
}
__attribute__((constructor(800)))
static void InstallDesktopControls(void)
{
    Class cls=NSClassFromString(@"JuiceController"); if(!cls)return;
    Method view=class_getInstanceMethod(cls,@selector(viewDidLoad));
    if(view)OriginalViewDidLoad=(void *)method_setImplementation(view,(IMP)ViewDidLoad);
    Method layout=class_getInstanceMethod(cls,@selector(viewDidLayoutSubviews));
    if(layout) {
        OriginalLayout=(void *)method_getImplementation(layout);
        if(!class_addMethod(cls,@selector(viewDidLayoutSubviews),(IMP)Layout,method_getTypeEncoding(layout)))
            OriginalLayout=(void *)method_setImplementation(layout,(IMP)Layout);
    }
    Method menu=class_getInstanceMethod(cls,NSSelectorFromString(@"rebuildExperimentalMenu"));
    if(menu)OriginalMenu=(void *)method_setImplementation(menu,(IMP)Menu);
}
