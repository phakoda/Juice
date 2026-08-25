#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void (*JuiceOriginalCompatibilityViewDidLoad)(id, SEL);
static void (*JuiceOriginalRebuildExperimentalMenu)(id, SEL);

static id JuiceCompatibilityValue(id self, NSString *key)
{
    @try { return [self valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceRenameCompatibilityLabel(UIView *view)
{
    if ([view isKindOfClass:UILabel.class])
    {
        UILabel *label = (UILabel *)view;
        if ([label.text isEqualToString:@"Experimental x86_64 (auto-detect)"])
            label.text = @"Experimental x86 / x86-64 (FEX)";
    }
    for (UIView *subview in view.subviews) JuiceRenameCompatibilityLabel(subview);
}

static void JuiceCompatibilityViewDidLoad(id self, SEL _cmd)
{
    if (JuiceOriginalCompatibilityViewDidLoad)
        JuiceOriginalCompatibilityViewDidLoad(self, _cmd);
    if ([self isKindOfClass:UIViewController.class])
        JuiceRenameCompatibilityLabel(((UIViewController *)self).view);
}

static void JuiceRebuildCompatibilityMenu(id self, SEL _cmd)
{
    if (JuiceOriginalRebuildExperimentalMenu)
        JuiceOriginalRebuildExperimentalMenu(self, _cmd);

    UIButton *button = JuiceCompatibilityValue(self, @"experimentalButton");
    if (![button isKindOfClass:UIButton.class] || !button.menu) return;

    NSMutableArray<UIMenuElement *> *children = [button.menu.children mutableCopy];
    for (NSUInteger index = 0; index < children.count; index++)
    {
        UIMenuElement *element = children[index];
        if (![element isKindOfClass:UIAction.class]) continue;
        UIAction *action = (UIAction *)element;
        if (![action.title isEqualToString:@"x86-64 / FEX translation"]) continue;

        __weak id weakSelf = self;
        UIAction *replacement = [UIAction actionWithTitle:@"x86 / x86-64 FEX translation"
                                                    image:action.image identifier:action.identifier
                                                  handler:^(__unused UIAction *selected) {
            id strongSelf = weakSelf;
            if (!strongSelf) return;
            BOOL enabled = ![JuiceCompatibilityValue(strongSelf, @"experimentalX64") boolValue];
            SEL selector = NSSelectorFromString(@"applyExperimentalX64Enabled:");
            if ([strongSelf respondsToSelector:selector])
                ((void (*)(id, SEL, BOOL))objc_msgSend)(strongSelf, selector, enabled);
        }];
        replacement.discoverabilityTitle = @"Run 32-bit x86 and x86-64 Windows apps through FEX";
        replacement.state = [JuiceCompatibilityValue(self, @"experimentalX64") boolValue]
            ? UIMenuElementStateOn : UIMenuElementStateOff;
        children[index] = replacement;
        break;
    }
    button.menu = [UIMenu menuWithTitle:button.menu.title children:children];
}

__attribute__((constructor(325)))
static void JuiceInstallCompatibilityLabels(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;

    Method view = class_getInstanceMethod(cls, NSSelectorFromString(@"viewDidLoad"));
    if (view)
        JuiceOriginalCompatibilityViewDidLoad = (void (*)(id, SEL))
            method_setImplementation(view, (IMP)JuiceCompatibilityViewDidLoad);

    Method menu = class_getInstanceMethod(cls, NSSelectorFromString(@"rebuildExperimentalMenu"));
    if (menu)
        JuiceOriginalRebuildExperimentalMenu = (void (*)(id, SEL))
            method_setImplementation(menu, (IMP)JuiceRebuildCompatibilityMenu);
}
