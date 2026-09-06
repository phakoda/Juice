#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void (*JuiceMemoryOriginalWarning)(id,SEL);

static id JuiceMemoryValue(id object,NSString *key){@try{return [object valueForKey:key];}@catch(__unused NSException *e){return nil;}}
static void JuiceMemorySetValue(id object,NSString *key,id value){@try{[object setValue:value forKey:key];}@catch(__unused NSException *e){}}
static void JuiceMemoryAppend(id self,NSString *line){SEL s=NSSelectorFromString(@"append:");if([self respondsToSelector:s])((void(*)(id,SEL,id))objc_msgSend)(self,s,line);}

static uint64_t JuiceApproximateImageBytes(UIImage *image)
{
    CGImageRef cg=image.CGImage;if(!cg)return 0;
    size_t row=CGImageGetBytesPerRow(cg),height=CGImageGetHeight(cg);
    if(height&&row>UINT64_MAX/height)return UINT64_MAX;
    return (uint64_t)row*height;
}

static void JuiceMemoryWarning(id self,SEL _cmd)
{
    if(JuiceMemoryOriginalWarning)JuiceMemoryOriginalWarning(self,_cmd);
    NSMutableDictionary *windows=JuiceMemoryValue(self,@"wineWindows");
    if(![windows isKindOfClass:NSMutableDictionary.class])return;

    __block NSUInteger trimmed=0;__block uint64_t approximateBytes=0;
    [windows enumerateKeysAndObjectsUsingBlock:^(NSNumber *key,id state,BOOL *stop){
        (void)key;(void)stop;
        if([JuiceMemoryValue(state,@"visible") boolValue])return;
        UIImage *image=JuiceMemoryValue(state,@"image");if(![image isKindOfClass:UIImage.class])return;
        uint64_t bytes=JuiceApproximateImageBytes(image);
        if(UINT64_MAX-approximateBytes<bytes)approximateBytes=UINT64_MAX;else approximateBytes+=bytes;
        JuiceMemorySetValue(state,@"image",nil);trimmed++;
    }];

    if([JuiceMemoryValue(self,@"experimentalMultiWindow") boolValue])
        JuiceMemorySetValue(self,@"lastLegacyImage",nil);
    [NSURLCache.sharedURLCache removeAllCachedResponses];

    if(trimmed&&[JuiceMemoryValue(self,@"experimentalMultiWindow") boolValue])
    {
        SEL composite=NSSelectorFromString(@"compositeWineDesktop");
        if([self respondsToSelector:composite])((void(*)(id,SEL))objc_msgSend)(self,composite);
    }
    JuiceMemoryAppend(self,[NSString stringWithFormat:@"MEMORY_PRESSURE hidden_images_trimmed=%lu approx_bytes=%llu tracked_windows=%lu\n",(unsigned long)trimmed,(unsigned long long)approximateBytes,(unsigned long)windows.count]);
}

__attribute__((constructor(400)))
static void JuiceInstallMemoryPressure(void)
{
    Class cls=NSClassFromString(@"JuiceController");if(!cls)return;
    SEL selector=@selector(didReceiveMemoryWarning);
    Method inherited=class_getInstanceMethod(cls,selector);if(!inherited)return;
    JuiceMemoryOriginalWarning=(void(*)(id,SEL))method_getImplementation(inherited);
    if(!class_addMethod(cls,selector,(IMP)JuiceMemoryWarning,method_getTypeEncoding(inherited)))
    {
        Method direct=class_getInstanceMethod(cls,selector);
        if(direct)JuiceMemoryOriginalWarning=(void(*)(id,SEL))method_setImplementation(direct,(IMP)JuiceMemoryWarning);
    }
}
