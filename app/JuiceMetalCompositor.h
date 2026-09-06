#ifndef JUICE_METAL_COMPOSITOR_H
#define JUICE_METAL_COMPOSITOR_H
#import <UIKit/UIKit.h>

/* The immutable transport bytes are shared with the UIImage provider, not copied. */
void JuiceAttachPixelBacking(UIImage *image, NSData *data, int width, int height, uint32_t stride);
@interface JuiceCompositeWindow : NSObject
@property(nonatomic, strong) NSNumber *identifier;
@property(nonatomic, strong) UIImage *image;
@property(nonatomic) CGRect frame;
@end
/* Main queue only. NO means the caller must render its existing CPU fallback. */
BOOL JuicePresentMetalComposite(UIImageView *canvas, NSArray<JuiceCompositeWindow *> *windows,
                                 CGRect viewport, void (^fallback)(void));
void JuiceHideMetalComposite(UIImageView *canvas);
void JuiceResetMetalComposite(UIImageView *canvas);
CGSize JuiceCanvasContentSize(UIImageView *canvas);
NSDictionary<NSString *, NSNumber *> *JuiceMetalStatistics(UIImageView *canvas);
#endif
