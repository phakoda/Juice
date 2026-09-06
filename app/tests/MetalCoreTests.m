#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <assert.h>
#import <math.h>
#import "../JuiceMetalCore.h"

static JuiceMetalLayer *Layer(NSNumber *identifier, const uint8_t *bytes,
                             int width, int height, uint32_t stride, JuiceRect frame)
{
    JuiceMetalLayer *layer = [JuiceMetalLayer new];
    layer.identifier = identifier;
    layer.pixels = [NSData dataWithBytes:bytes length:(NSUInteger)stride * height];
    layer.width = width; layer.height = height; layer.stride = stride; layer.frame = frame;
    return layer;
}
static id<MTLTexture> Target(id<MTLDevice> device)
{
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:4 height:4 mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [device newTextureWithDescriptor:d]; assert(target);
    return target;
}
static NSData *Readback(id<MTLDevice> device, id<MTLTexture> target)
{
    const NSUInteger stride = 256;
    id<MTLBuffer> buffer = [device newBufferWithLength:stride * 4 options:MTLResourceStorageModeShared];
    assert(buffer);
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
              sourceSize:MTLSizeMake(4,4,1) toBuffer:buffer destinationOffset:0
    destinationBytesPerRow:stride destinationBytesPerImage:stride * 4];
    [blit endEncoding]; [command commit]; [command waitUntilCompleted];
    assert(command.status == MTLCommandBufferStatusCompleted);
    NSMutableData *result = [NSMutableData dataWithLength:64];
    for (NSUInteger y = 0; y < 4; y++)
        memcpy((uint8_t *)result.mutableBytes + y * 16, (uint8_t *)buffer.contents + y * stride, 16);
    return result;
}
static NSData *Render(JuiceMetalCore *core, NSArray *layers, JuiceRect viewport,
                      id<MTLTexture> target, BOOL linear)
{
    NSError *error = nil;
    id<MTLCommandBuffer> command = [core encodeLayers:layers viewport:viewport target:target linear:linear error:&error];
    if (!command) NSLog(@"Unexpected render failure: %@", error);
    assert(command);
    [command commit]; [command waitUntilCompleted];
    assert(command.status == MTLCommandBufferStatusCompleted);
    return Readback(core.device, target);
}
static void Pixel(NSData *data, int x, int y, unsigned b, unsigned g, unsigned r)
{
    const uint8_t *pixel = (const uint8_t *)data.bytes + (y * 4 + x) * 4;
    if (pixel[0] != b || pixel[1] != g || pixel[2] != r || pixel[3] != 255)
        fprintf(stderr, "Pixel %d,%d actual=%u,%u,%u,%u expected=%u,%u,%u,255\n",
                x,y,pixel[0],pixel[1],pixel[2],pixel[3],b,g,r);
    assert(pixel[0] == b && pixel[1] == g && pixel[2] == r && pixel[3] == 255);
}
int main(void)
{
    @autoreleasepool {
        if (!MTLCreateSystemDefaultDevice()) {
            puts("METAL_CORE_TESTS_SKIP reason=no-metal-device gpu-pixels-not-validated");
            return 0;
        }
        NSError *error = nil;
        JuiceMetalCore *core = [[JuiceMetalCore alloc] initWithError:&error];
        if (!core) NSLog(@"Metal initialization failed with an available device: %@", error);
        assert(core);
        id<MTLTexture> target = Target(core.device);
        JuiceRect viewport = {0,0,4,4};
        /* Deliberately zero the X byte: Wine XRGB is opaque, not transparent. */
        uint8_t bytes[24] = {0,0,255,0, 0,255,0,0, 0xaa,0xaa,0xaa,0xaa,
                             255,0,0,0, 255,255,255,0, 0xbb,0xbb,0xbb,0xbb};
        JuiceMetalLayer *a = Layer(@1,bytes,2,2,12,(JuiceRect){1,1,2,2});
        NSData *image = Render(core,@[a],viewport,target,NO);
        Pixel(image,0,0,0,0,0); Pixel(image,1,1,0,0,255); Pixel(image,2,1,0,255,0);
        Pixel(image,1,2,255,0,0); Pixel(image,2,2,255,255,255); Pixel(image,3,3,0,0,0);
        assert(core.uploadedBytes == 16 && core.textureBytes > 0);
        Render(core,@[a],viewport,target,NO); assert(core.uploadedBytes == 16);

        /* Cropped backing pixels retain one-to-one mapping after a resize. */
        a.frame = (JuiceRect){1,1,1,1};
        image = Render(core,@[a],viewport,target,NO);
        Pixel(image,1,1,0,0,255); Pixel(image,2,1,0,0,0); Pixel(image,1,2,0,0,0);
        a.frame = (JuiceRect){-1,-1,2,2};
        image = Render(core,@[a],viewport,target,NO); Pixel(image,0,0,255,255,255);
        a.frame = (JuiceRect){11,11,2,2};
        image = Render(core,@[a],(JuiceRect){10,10,4,4},target,NO); Pixel(image,1,1,0,0,255);

        /* Ordered windows: an opaque front window occludes the back window. */
        uint8_t yellow[] = {0,255,255,0};
        JuiceMetalLayer *b = Layer(@2,yellow,1,1,4,(JuiceRect){1,1,1,1});
        a.frame = (JuiceRect){1,1,2,2};
        image = Render(core,@[a,b],viewport,target,NO); Pixel(image,1,1,0,255,255);
        Pixel(image,2,1,0,255,0);
        image = Render(core,@[b,a],viewport,target,NO); Pixel(image,1,1,0,0,255);
        assert(core.uploadedBytes == 20);

        /* CPU-visible textures cannot be mutated before an encoded frame retires. */
        id<MTLCommandBuffer> held = [core encodeLayers:@[a] viewport:viewport target:target linear:NO error:&error];
        assert(held);
        assert(![core encodeLayers:@[a] viewport:viewport target:target linear:NO error:&error]);
        assert(error);
        [held commit]; [held waitUntilCompleted]; assert(held.status == MTLCommandBufferStatusCompleted);

        /* Changing an immutable snapshot uploads once, including texture resize. */
        uint64_t before = core.uploadedBytes;
        uint8_t cyan[] = {255,255,0,0};
        a.pixels = [NSData dataWithBytes:cyan length:4]; a.width = a.height = 1; a.stride = 4;
        a.frame = (JuiceRect){2,2,1,1};
        image = Render(core,@[a],viewport,target,YES); Pixel(image,2,2,255,255,0);
        assert(core.uploadedBytes == before + 4);
        assert(![core encodeLayers:@[a,a] viewport:viewport target:target linear:NO error:&error]);
        assert(![core encodeLayers:@[a] viewport:(JuiceRect){NAN,0,4,4} target:target linear:NO error:&error]);
        a.stride = UINT32_MAX;
        assert(![core encodeLayers:@[a] viewport:viewport target:target linear:NO error:&error]);
        a.stride = 4;
        [core purgeTextures]; assert(core.textureBytes == 0);
        image = Render(core,@[],viewport,target,NO);
        for (int y=0;y<4;y++) for(int x=0;x<4;x++) Pixel(image,x,y,0,0,0);
        for (unsigned iteration=0;iteration<64;iteration++) {
            uint8_t color[] = {(uint8_t)iteration,(uint8_t)(255-iteration),(uint8_t)(iteration*3),0};
            a.pixels = [NSData dataWithBytes:color length:4];
            a.frame = (JuiceRect){iteration%4,(iteration/4)%4,1,1};
            image = Render(core,@[a],viewport,target,NO);
            Pixel(image,iteration%4,(iteration/4)%4,color[0],color[1],color[2]);
        }
        puts("METAL_CORE_TESTS_OK opaque-xrgb orientation stride clipping viewport occlusion cache flight resize bounds mutations=64");
    }
    return 0;
}
