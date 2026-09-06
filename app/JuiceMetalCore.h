#ifndef JUICE_METAL_CORE_H
#define JUICE_METAL_CORE_H
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "JuicePresentationPolicy.h"

/* Immutable for the duration of encodeLayers:. No UIKit dependencies, so the
 * exact production GPU path can also be tested on a macOS build host. */
@interface JuiceMetalLayer : NSObject
@property(nonatomic, strong) NSNumber *identifier;
@property(nonatomic, strong) NSData *pixels;
@property(nonatomic) int width, height;
@property(nonatomic) uint32_t stride;
@property(nonatomic) JuiceRect frame;
@end

@interface JuiceMetalCore : NSObject
@property(nonatomic, readonly) id<MTLDevice> device;
@property(nonatomic, readonly) NSUInteger textureBytes;
@property(nonatomic, readonly) uint64_t uploadedBytes;
- (instancetype)initWithError:(NSError **)error;
/* Serial owner queue only. Commit the returned buffer before encoding again.
 * Refuses CPU texture mutation until the previous command buffer completes. */
- (id<MTLCommandBuffer>)encodeLayers:(NSArray<JuiceMetalLayer *> *)layers
                          viewport:(JuiceRect)viewport
                            target:(id<MTLTexture>)target
                            linear:(BOOL)linear error:(NSError **)error;
- (void)purgeTextures;
@end
#endif
