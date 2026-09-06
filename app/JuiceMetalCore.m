#import "JuiceMetalCore.h"

static const NSUInteger TextureBudget = 128u * 1024u * 1024u;
static const NSUInteger SceneBudget = 96u * 1024u * 1024u;

static NSString *const Shader =
    @"#include <metal_stdlib>\nusing namespace metal;\n"
     "struct Vertex { float2 position; float2 uv; };\n"
     "struct Varying { float4 position [[position]]; float2 uv; };\n"
     "vertex Varying juice_vertex(uint i [[vertex_id]], const device Vertex *v [[buffer(0)]]) {\n"
     "  Varying o; o.position=float4(v[i].position,0.0,1.0); o.uv=v[i].uv; return o; }\n"
     "fragment float4 juice_fragment(Varying v [[stage_in]], texture2d<float> image [[texture(0)]],\n"
     "                                sampler s [[sampler(0)]]) {\n"
     "  return float4(image.sample(s,v.uv).rgb,1.0); }\n";

static void Fail(NSError **error, NSString *message)
{
    if (error) *error = [NSError errorWithDomain:@"org.juice.metal" code:1
                                       userInfo:@{NSLocalizedDescriptionKey: message}];
}
@implementation JuiceMetalLayer
@end

@interface JuiceTextureEntry : NSObject
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic, weak) NSData *source;
@end
@implementation JuiceTextureEntry
@end

@implementation JuiceMetalCore {
    id<MTLCommandQueue> _commands;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLSamplerState> _nearest, _linear;
    NSMutableDictionary<NSNumber *, JuiceTextureEntry *> *_textures;
    __weak id<MTLCommandBuffer> _previous;
}
- (instancetype)initWithError:(NSError **)error
{
    if (!(self = [super init])) return nil;
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) { Fail(error, @"No Metal device is available."); return nil; }
    _commands = [_device newCommandQueueWithMaxCommandBufferCount:1];
    id<MTLLibrary> library = [_device newLibraryWithSource:Shader options:nil error:error];
    if (!library || !_commands) { if (!library && error && *error) return nil;
        Fail(error, @"Could not create Metal commands or shaders."); return nil; }
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"juice_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"juice_fragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    descriptor.colorAttachments[0].blendingEnabled = NO; /* Wire frames are opaque XRGB. */
    _pipeline = [_device newRenderPipelineStateWithDescriptor:descriptor error:error];
    if (!_pipeline) return nil;
    MTLSamplerDescriptor *sample = [MTLSamplerDescriptor new];
    sample.sAddressMode = sample.tAddressMode = MTLSamplerAddressModeClampToEdge;
    sample.minFilter = sample.magFilter = MTLSamplerMinMagFilterNearest;
    _nearest = [_device newSamplerStateWithDescriptor:sample];
    sample.minFilter = sample.magFilter = MTLSamplerMinMagFilterLinear;
    _linear = [_device newSamplerStateWithDescriptor:sample];
    if (!_nearest || !_linear) { Fail(error, @"Could not create Metal samplers."); return nil; }
    _textures = [NSMutableDictionary dictionary];
    return self;
}
- (void)purgeTextures
{
    /* Submitted command buffers retain their own resources. Purging references
     * is safe even during a flight; the next encode still checks completion. */
    [_textures removeAllObjects];
    _textureBytes = 0;
}
- (id<MTLCommandBuffer>)encodeLayers:(NSArray<JuiceMetalLayer *> *)layers
                          viewport:(JuiceRect)viewport target:(id<MTLTexture>)target
                            linear:(BOOL)linear error:(NSError **)error
{
    if (_previous && _previous.status != MTLCommandBufferStatusCompleted &&
        _previous.status != MTLCommandBufferStatusError) {
        Fail(error, @"A frame is already in flight."); return nil;
    }
    _previous = nil;
    JuiceVertex check[4];
    if (layers.count > 128 || !target || target.pixelFormat != MTLPixelFormatBGRA8Unorm ||
        target.width > 8192 || target.height > 8192 ||
        (uint64_t)target.width * target.height > 4096ULL * 4096ULL ||
        !JuiceCompositeQuad(viewport, viewport, 1, 1, check)) {
        Fail(error, @"Invalid or oversized composite geometry."); return nil;
    }
    NSMutableSet<NSNumber *> *identifiers = [NSMutableSet set];
    NSUInteger estimate = 0;
    for (JuiceMetalLayer *layer in layers) {
        if (![layer.identifier isKindOfClass:NSNumber.class] || [identifiers containsObject:layer.identifier] ||
            !JuicePixelLayoutValid(layer.width, layer.height, layer.stride, layer.pixels.length, NULL)) {
            Fail(error, @"Invalid, duplicated, or incomplete window surface."); return nil;
        }
        NSUInteger bytes = (NSUInteger)layer.width * (NSUInteger)layer.height * 4;
        if (bytes > SceneBudget - estimate) { Fail(error, @"Composite exceeds the GPU scene budget."); return nil; }
        estimate += bytes;
        [identifiers addObject:layer.identifier];
    }
    for (NSNumber *identifier in [_textures.allKeys copy])
        if (![identifiers containsObject:identifier]) [_textures removeObjectForKey:identifier];
    _textureBytes = 0;
    for (JuiceTextureEntry *entry in _textures.allValues) _textureBytes += entry.texture.allocatedSize;

    for (JuiceMetalLayer *layer in layers) {
        JuiceTextureEntry *entry = _textures[layer.identifier];
        if (entry && (entry.texture.width != (NSUInteger)layer.width ||
                      entry.texture.height != (NSUInteger)layer.height)) {
            _textureBytes -= entry.texture.allocatedSize;
            [_textures removeObjectForKey:layer.identifier]; entry = nil;
        }
        if (!entry) {
            NSUInteger estimateBytes = (NSUInteger)layer.width * (NSUInteger)layer.height * 4;
            if (_textureBytes > TextureBudget || estimateBytes > TextureBudget - _textureBytes) {
                Fail(error, @"Texture cache exceeds its memory budget."); return nil;
            }
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                width:(NSUInteger)layer.width height:(NSUInteger)layer.height mipmapped:NO];
            d.storageMode = MTLStorageModeShared;
            d.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> texture = [_device newTextureWithDescriptor:d];
            if (!texture || texture.allocatedSize > TextureBudget - _textureBytes) {
                Fail(error, @"Metal texture allocation failed or exceeded its budget."); return nil;
            }
            entry = [JuiceTextureEntry new]; entry.texture = texture;
            _textures[layer.identifier] = entry; _textureBytes += texture.allocatedSize;
        }
        if (entry.source != layer.pixels) {
            [entry.texture replaceRegion:MTLRegionMake2D(0, 0, layer.width, layer.height)
                             mipmapLevel:0 withBytes:layer.pixels.bytes bytesPerRow:layer.stride];
            entry.source = layer.pixels;
            _uploadedBytes += (uint64_t)layer.width * (unsigned)layer.height * 4;
        }
    }
    id<MTLCommandBuffer> command = [_commands commandBuffer];
    if (!command) { Fail(error, @"Could not allocate a Metal command buffer."); return nil; }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    if (!encoder) { Fail(error, @"Could not encode a Metal render pass."); return nil; }
    [encoder setRenderPipelineState:_pipeline];
    [encoder setFragmentSamplerState:linear ? _linear : _nearest atIndex:0];
    for (JuiceMetalLayer *layer in layers) {
        JuiceVertex quad[4];
        if (!JuiceCompositeQuad(viewport, layer.frame, layer.width, layer.height, quad)) continue;
        [encoder setVertexBytes:quad length:sizeof(quad) atIndex:0];
        [encoder setFragmentTexture:_textures[layer.identifier].texture atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [encoder endEncoding];
    _previous = command;
    return command;
}
@end
