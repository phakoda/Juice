#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define JUICE_KEYBOARD_MAGIC 0x4a554943u
#define JUICE_KEYBOARD_TEXT 101u
#define JUICE_KEYBOARD_KEY 102u
#define JUICE_KEY_SHIFT   0x00010000u
#define JUICE_KEY_CONTROL 0x00020000u
#define JUICE_KEY_ALT     0x00040000u

typedef struct
{
    uint32_t magic, type, size;
    uint64_t hwnd;
    int32_t x, y, width, height;
    uint32_t stride, flags;
} JuiceKeyboardMsg;

static void (*JuiceOriginalPressesBegan)(id, SEL, NSSet<UIPress *> *, UIPressesEvent *);
static char JuiceHardwareKeyboardLoggedKey;

static id JuiceKeyboardValue(id object, NSString *key)
{
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL JuiceHasEditingResponder(UIView *view)
{
    if (view.isFirstResponder &&
        ([view isKindOfClass:UITextField.class] || [view isKindOfClass:UITextView.class])) return YES;
    for (UIView *subview in view.subviews)
        if (JuiceHasEditingResponder(subview)) return YES;
    return NO;
}

static BOOL JuiceHasWineKeyboardTarget(id self)
{
    id canvas = JuiceKeyboardValue(self, @"canvas");
    uint64_t hwnd = [JuiceKeyboardValue(canvas, @"hwnd") unsignedLongLongValue];
    int client = [JuiceKeyboardValue(self, @"activeClient") intValue];
    return hwnd != 0 && client >= 0;
}

static void JuiceHardwareAppend(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static void JuiceMarkHardwareKeyboardActive(id self)
{
    if ([objc_getAssociatedObject(self, &JuiceHardwareKeyboardLoggedKey) boolValue]) return;
    objc_setAssociatedObject(self, &JuiceHardwareKeyboardLoggedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    JuiceHardwareAppend(self, @"HARDWARE_KEYBOARD_ACTIVE forwarding=wine modifiers=1\n");
}

static BOOL JuiceBroadcastKeyboardMessage(id self, JuiceKeyboardMsg *message, NSData *payload)
{
    if (!JuiceHasWineKeyboardTarget(self)) return NO;
    SEL selector = NSSelectorFromString(@"broadcastMessage:payload:");
    if (![self respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL, JuiceKeyboardMsg *, id))objc_msgSend)
        (self, selector, message, payload);
}

static BOOL JuiceSendWineText(id self, NSString *text)
{
    if (!text.length || !JuiceHasWineKeyboardTarget(self)) return NO;
    id canvas = JuiceKeyboardValue(self, @"canvas");
    uint64_t hwnd = [JuiceKeyboardValue(canvas, @"hwnd") unsignedLongLongValue];

    NSData *payload = [text dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    if (!payload.length || payload.length > UINT32_MAX) return NO;

    JuiceKeyboardMsg message = {JUICE_KEYBOARD_MAGIC, JUICE_KEYBOARD_TEXT, 0, hwnd, 0, 0, 0, 0, 0, 0};
    return JuiceBroadcastKeyboardMessage(self, &message, payload);
}

static BOOL JuiceSendWineVirtualKey(id self, uint32_t vkey, uint32_t modifiers, NSString *name)
{
    if (!JuiceHasWineKeyboardTarget(self) || !(vkey & 0xffffu)) return NO;
    id canvas = JuiceKeyboardValue(self, @"canvas");
    uint64_t hwnd = [JuiceKeyboardValue(canvas, @"hwnd") unsignedLongLongValue];
    JuiceKeyboardMsg message = {
        JUICE_KEYBOARD_MAGIC, JUICE_KEYBOARD_KEY, 0, hwnd,
        0, 0, 0, 0, 0, (vkey & 0xffffu) | modifiers
    };
    BOOL delivered = JuiceBroadcastKeyboardMessage(self, &message, nil);
    JuiceHardwareAppend(self, [NSString stringWithFormat:
        @"HARDWARE_KEY_SENT hwnd=0x%llx key=%@ vk=0x%x modifiers=0x%x delivered=%d\n",
        (unsigned long long)hwnd, name ?: @"key", vkey, modifiers, delivered]);
    return delivered;
}

static BOOL JuicePasteIOSClipboard(id self)
{
    if (!JuiceHasWineKeyboardTarget(self)) return NO;
    SEL selector = NSSelectorFromString(@"juice_pasteIOSClipboard:");
    if (![self respondsToSelector:selector]) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(self, selector, nil);
    return YES;
}

static uint32_t JuiceVirtualKeyForHID(NSInteger hid, NSString **name)
{
    uint32_t key = 0;
    NSString *label = nil;

    if (hid >= 0x04 && hid <= 0x1d)
    {
        key = 0x41u + (uint32_t)(hid - 0x04);
        label = [NSString stringWithFormat:@"%C", (unichar)('A' + hid - 0x04)];
    }
    else if (hid >= 0x1e && hid <= 0x26)
    {
        key = 0x31u + (uint32_t)(hid - 0x1e);
        label = [NSString stringWithFormat:@"%C", (unichar)('1' + hid - 0x1e)];
    }
    else switch (hid)
    {
        case 0x27: key = 0x30; label = @"0"; break;
        case 0x28: key = 0x0d; label = @"enter"; break;
        case 0x29: key = 0x1b; label = @"escape"; break;
        case 0x2a: key = 0x08; label = @"backspace"; break;
        case 0x2b: key = 0x09; label = @"tab"; break;
        case 0x2c: key = 0x20; label = @"space"; break;
        case 0x2d: key = 0xbd; label = @"minus"; break;
        case 0x2e: key = 0xbb; label = @"equals"; break;
        case 0x2f: key = 0xdb; label = @"left-bracket"; break;
        case 0x30: key = 0xdd; label = @"right-bracket"; break;
        case 0x31: key = 0xdc; label = @"backslash"; break;
        case 0x33: key = 0xba; label = @"semicolon"; break;
        case 0x34: key = 0xde; label = @"quote"; break;
        case 0x35: key = 0xc0; label = @"grave"; break;
        case 0x36: key = 0xbc; label = @"comma"; break;
        case 0x37: key = 0xbe; label = @"period"; break;
        case 0x38: key = 0xbf; label = @"slash"; break;
        case 0x39: key = 0x14; label = @"caps-lock"; break;
        case 0x3a: key = 0x70; label = @"f1"; break;
        case 0x3b: key = 0x71; label = @"f2"; break;
        case 0x3c: key = 0x72; label = @"f3"; break;
        case 0x3d: key = 0x73; label = @"f4"; break;
        case 0x3e: key = 0x74; label = @"f5"; break;
        case 0x3f: key = 0x75; label = @"f6"; break;
        case 0x40: key = 0x76; label = @"f7"; break;
        case 0x41: key = 0x77; label = @"f8"; break;
        case 0x42: key = 0x78; label = @"f9"; break;
        case 0x43: key = 0x79; label = @"f10"; break;
        case 0x44: key = 0x7a; label = @"f11"; break;
        case 0x45: key = 0x7b; label = @"f12"; break;
        case 0x46: key = 0x2c; label = @"print-screen"; break;
        case 0x47: key = 0x91; label = @"scroll-lock"; break;
        case 0x48: key = 0x13; label = @"pause"; break;
        case 0x49: key = 0x2d; label = @"insert"; break;
        case 0x4a: key = 0x24; label = @"home"; break;
        case 0x4b: key = 0x21; label = @"page-up"; break;
        case 0x4c: key = 0x2e; label = @"delete"; break;
        case 0x4d: key = 0x23; label = @"end"; break;
        case 0x4e: key = 0x22; label = @"page-down"; break;
        case 0x4f: key = 0x27; label = @"right"; break;
        case 0x50: key = 0x25; label = @"left"; break;
        case 0x51: key = 0x28; label = @"down"; break;
        case 0x52: key = 0x26; label = @"up"; break;
        default: break;
    }
    if (name) *name = label;
    return key;
}

static uint32_t JuiceWindowsModifiers(UIKeyModifierFlags modifiers)
{
    uint32_t result = 0;
    if (modifiers & UIKeyModifierShift) result |= JUICE_KEY_SHIFT;
    if (modifiers & (UIKeyModifierControl | UIKeyModifierCommand)) result |= JUICE_KEY_CONTROL;
    if (modifiers & UIKeyModifierAlternate) result |= JUICE_KEY_ALT;
    return result;
}

static BOOL JuiceCommandShortcutShouldReachWine(NSString *plain)
{
    static NSSet<NSString *> *aliases;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        aliases = [NSSet setWithArray:@[@"a", @"b", @"c", @"f", @"i", @"l", @"n", @"o",
                                        @"p", @"r", @"s", @"t", @"u", @"w", @"x", @"y", @"z"]];
    });
    return [aliases containsObject:plain.lowercaseString];
}

static void JuiceHardwarePressesBegan(id self, SEL _cmd, NSSet<UIPress *> *presses,
                                      UIPressesEvent *event)
{
    UIViewController *controller = [self isKindOfClass:UIViewController.class] ? self : nil;
    if (!controller || JuiceHasEditingResponder(controller.view))
    {
        if (JuiceOriginalPressesBegan) JuiceOriginalPressesBegan(self, _cmd, presses, event);
        return;
    }

    BOOL handledAny = NO;
    BOOL shouldForwardOriginal = NO;
    for (UIPress *press in presses)
    {
        UIKey *key = press.key;
        if (!key)
        {
            shouldForwardOriginal = YES;
            continue;
        }

        UIKeyModifierFlags modifiers = key.modifierFlags;
        NSString *plain = key.charactersIgnoringModifiers.lowercaseString ?: @"";
        if (modifiers == UIKeyModifierCommand && [plain isEqualToString:@"v"])
        {
            BOOL delivered = JuicePasteIOSClipboard(self);
            handledAny |= delivered;
            shouldForwardOriginal |= !delivered;
            continue;
        }

        BOOL command = (modifiers & UIKeyModifierCommand) != 0;
        BOOL controlOrAlt = (modifiers & (UIKeyModifierControl | UIKeyModifierAlternate)) != 0;
        BOOL commandAlias = command && JuiceCommandShortcutShouldReachWine(plain);
        if (command && !commandAlias && !controlOrAlt)
        {
            /* Preserve iPadOS-level shortcuts such as Command-Tab, Command-Space
               and Command-H instead of converting every Command chord to Ctrl. */
            shouldForwardOriginal = YES;
            continue;
        }

        NSString *name = nil;
        uint32_t vkey = JuiceVirtualKeyForHID((NSInteger)key.keyCode, &name);
        if (controlOrAlt || commandAlias)
        {
            BOOL delivered = vkey && JuiceSendWineVirtualKey(self, vkey,
                JuiceWindowsModifiers(modifiers), name ?: plain ?: @"key");
            handledAny |= delivered;
            shouldForwardOriginal |= !delivered;
            continue;
        }

        NSString *characters = key.characters;
        if (characters.length &&
            [characters rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound)
        {
            BOOL delivered = JuiceSendWineText(self, characters);
            handledAny |= delivered;
            shouldForwardOriginal |= !delivered;
            continue;
        }

        if (vkey)
        {
            BOOL delivered = JuiceSendWineVirtualKey(self, vkey,
                JuiceWindowsModifiers(modifiers), name ?: @"key");
            handledAny |= delivered;
            shouldForwardOriginal |= !delivered;
            continue;
        }
        shouldForwardOriginal = YES;
    }

    if (handledAny) JuiceMarkHardwareKeyboardActive(self);
    if (shouldForwardOriginal && JuiceOriginalPressesBegan)
        JuiceOriginalPressesBegan(self, _cmd, presses, event);
}

__attribute__((constructor(350)))
static void JuiceInstallHardwareKeyboard(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;
    SEL selector = @selector(pressesBegan:withEvent:);
    Method inherited = class_getInstanceMethod(cls, selector);
    if (!inherited) return;

    JuiceOriginalPressesBegan = (void (*)(id, SEL, NSSet<UIPress *> *, UIPressesEvent *))
        method_getImplementation(inherited);

    /* class_addMethod creates a JuiceController-specific override without
       mutating UIResponder's inherited implementation globally. */
    if (!class_addMethod(cls, selector, (IMP)JuiceHardwarePressesBegan,
                         method_getTypeEncoding(inherited)))
    {
        Method direct = class_getInstanceMethod(cls, selector);
        if (direct)
            JuiceOriginalPressesBegan = (void (*)(id, SEL, NSSet<UIPress *> *, UIPressesEvent *))
                method_setImplementation(direct, (IMP)JuiceHardwarePressesBegan);
    }
}
