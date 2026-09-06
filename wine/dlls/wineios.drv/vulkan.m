/* MoltenVK surface bridge for the Wine iOS driver. LGPL-2.1-or-later. */
#if 0
#pragma makedep unix
#endif

#include "config.h"

/* Keep Cocoa's one-byte BOOL distinct from Win32's 32-bit BOOL. */
#define BOOL JUICE_OBJC_BOOL
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#undef BOOL

#include <assert.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#include "graphics_policy.h"

#include "ntstatus.h"
#include "iosdrv.h"
#include "ipc.h"
#include "wine/debug.h"
#include "wine/vulkan.h"
#include "wine/vulkan_driver.h"

WINE_DEFAULT_DEBUG_CHANNEL(vulkan);

@interface JuiceIOSMetalLayer : CAMetalLayer
{
    id<CAMetalDrawable> last_drawable;
}
-(id<CAMetalDrawable>)copyLastDrawable;
-(void)clearLastDrawable;
@end

@implementation JuiceIOSMetalLayer
-(id<CAMetalDrawable>)nextDrawable
{
    id<CAMetalDrawable> drawable = [super nextDrawable];
    @synchronized(self)
    {
        [last_drawable release];
        last_drawable = [drawable retain];
    }
    return drawable;
}
-(id<CAMetalDrawable>)copyLastDrawable
{
    @synchronized(self) { return [last_drawable retain]; }
}
-(void)clearLastDrawable
{
    @synchronized(self)
    {
        [last_drawable release];
        last_drawable = nil;
    }
}
-(void)dealloc
{
    [last_drawable release];
    [super dealloc];
}
@end

struct iosdrv_client_surface
{
    struct client_surface client;
    JuiceIOSMetalLayer *layer;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLBuffer> readback;
    NSUInteger readback_size;
    NSUInteger readback_stride;
    unsigned int present_count;
    BOOL detached;
};

static pthread_mutex_t readback_budget_lock = PTHREAD_MUTEX_INITIALIZER;
static size_t readback_budget_used;
static void iosdrv_release_readback_budget(size_t bytes)
{
    pthread_mutex_lock(&readback_budget_lock);
    assert(bytes <= readback_budget_used);
    readback_budget_used -= bytes;
    pthread_mutex_unlock(&readback_budget_lock);
}

static const struct client_surface_funcs iosdrv_client_surface_funcs;
static const struct vulkan_driver_funcs iosdrv_vulkan_driver_funcs;

static struct iosdrv_client_surface *impl_from_client_surface(struct client_surface *client)
{
    assert(client && client->funcs == &iosdrv_client_surface_funcs);
    return CONTAINING_RECORD(client, struct iosdrv_client_surface, client);
}

static void iosdrv_client_surface_destroy(struct client_surface *client)
{
    struct iosdrv_client_surface *surface = impl_from_client_surface(client);
    /* The final client reference owns teardown. Break the drawable/layer
     * retention chain explicitly; dealloc alone cannot break a retain cycle. */
    [surface->layer clearLastDrawable];
    [surface->readback release];
    iosdrv_release_readback_budget(surface->readback_size);
    [surface->queue release];
    [surface->layer release];
    [surface->device release];
}

static void iosdrv_client_surface_detach(struct client_surface *client)
{
    struct iosdrv_client_surface *surface = impl_from_client_surface(client);
    @synchronized(surface->queue)
    {
        surface->detached = TRUE;
        surface->layer.hidden = YES;
        [surface->layer clearLastDrawable];
    }
}

static void iosdrv_client_surface_update(struct client_surface *client)
{
    struct iosdrv_client_surface *surface = impl_from_client_surface(client);
    size_t width = juice_rect_extent(client->monitor_rect.left, client->monitor_rect.right);
    size_t height = juice_rect_extent(client->monitor_rect.top, client->monitor_rect.bottom);
    struct juice_readback_layout layout;
    CGSize size;

    if (!juice_readback_layout(width, height, 256, &layout))
    {
        WARN("refusing oversized Metal surface for %s\n", debugstr_client_surface(client));
        return;
    }
    size = CGSizeMake(width, height);
    @synchronized(surface->queue)
    {
        if (!surface->detached && !CGSizeEqualToSize(surface->layer.drawableSize, size))
        {
            surface->layer.bounds = CGRectMake(0, 0, width, height);
            surface->layer.drawableSize = size;
            TRACE("resized %s Metal surface to %lux%lu\n", debugstr_client_surface(client),
                  (unsigned long)width, (unsigned long)height);
        }
    }
}

static enum juice_readback_format iosdrv_readback_format(MTLPixelFormat format)
{
    switch (format)
    {
    case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB: return JUICE_READBACK_BGRA8;
    case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: return JUICE_READBACK_RGBA8;
    case MTLPixelFormatRGB10A2Unorm: return JUICE_READBACK_RGB10A2;
    case MTLPixelFormatBGR10A2Unorm: return JUICE_READBACK_BGR10A2;
    default: return JUICE_READBACK_UNSUPPORTED;
    }
}

static BOOL iosdrv_prepare_readback(struct iosdrv_client_surface *surface, NSUInteger width, NSUInteger height)
{
    struct juice_readback_layout layout;
    id<MTLBuffer> replacement;
    BOOL reserved;
    if (!juice_readback_layout(width, height, 256, &layout)) return FALSE;
    if (surface->readback && surface->readback_size >= layout.bytes && surface->readback_stride == layout.stride) return TRUE;

    /* Reserve across all surfaces, including the old buffer while replacing. */
    pthread_mutex_lock(&readback_budget_lock);
    reserved = juice_readback_budget_reserve(&readback_budget_used, layout.bytes);
    pthread_mutex_unlock(&readback_budget_lock);
    if (!reserved) return FALSE;
    replacement = [surface->device newBufferWithLength:layout.bytes options:MTLResourceStorageModeShared];
    if (!replacement)
    {
        iosdrv_release_readback_budget(layout.bytes);
        return FALSE; /* Keep a reusable previous buffer on allocation failure. */
    }
    [surface->readback release];
    iosdrv_release_readback_budget(surface->readback_size);
    surface->readback = replacement;
    surface->readback_size = layout.bytes;
    surface->readback_stride = layout.stride;
    return TRUE;
}

static void iosdrv_present_readback(struct client_surface *client)
{
    struct iosdrv_client_surface *surface = impl_from_client_surface(client);
    id<CAMetalDrawable> drawable = surface->detached ? nil : [surface->layer copyLastDrawable];
    id<MTLTexture> texture = drawable.texture;
    id<MTLCommandBuffer> command;
    id<MTLBlitCommandEncoder> blit;
    enum juice_readback_format format;
    NSUInteger width, height;
    RECT dirty;

    if (!drawable || !texture) goto done;
    width = texture.width;
    height = texture.height;
    format = iosdrv_readback_format(texture.pixelFormat);
    if (format == JUICE_READBACK_UNSUPPORTED || texture.sampleCount != 1 ||
        texture.textureType != MTLTextureType2D || texture.framebufferOnly)
    {
        WARN("unsupported Metal readback format/type for %s\n", debugstr_client_surface(client));
        goto done;
    }
    if (!iosdrv_prepare_readback(surface, width, height)) goto done;
    command = [surface->queue commandBuffer];
    blit = [command blitCommandEncoder];
    if (!command || !blit) goto done;
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(width, height, 1)
               toBuffer:surface->readback destinationOffset:0
      destinationBytesPerRow:surface->readback_stride
    destinationBytesPerImage:surface->readback_stride * height];
    [blit endEncoding];
    [command commit];
    /* Preserve synchronous readback until producer-queue synchronization is
     * available; completion on this queue is not a cross-queue render fence. */
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted)
    {
        ERR("Metal readback failed for %s: %s\n", debugstr_client_surface(client),
            [[command.error description] UTF8String]);
        goto done;
    }
    if (!juice_readback_to_bgra(surface->readback.contents, surface->readback_size, width, height,
                                surface->readback_stride, format)) goto done;

    SetRect(&dirty, 0, 0, (INT)width, (INT)height);
    ios_ipc_present(client->hwnd, surface->readback.contents, (unsigned int)width,
                    (unsigned int)height, (unsigned int)surface->readback_stride, &dirty);
    if (surface->present_count < 3)
        fprintf(stderr, "JUICE_MOLTENVK_PRESENT_OK hwnd=%p width=%lu height=%lu stride=%lu frame=%u\n",
                client->hwnd, (unsigned long)width, (unsigned long)height,
                (unsigned long)surface->readback_stride, ++surface->present_count);
done:
    [drawable release];
}

static void iosdrv_client_surface_present(struct client_surface *client, HDC hdc)
{
    struct iosdrv_client_surface *surface = impl_from_client_surface(client);
    (void)hdc;
    /* Win32 threads need not have a Cocoa run loop. Drain temporary Metal
     * objects per frame, and serialize buffer allocation/conversion/IPC reuse. */
    @autoreleasepool
    {
        @synchronized(surface->queue) { iosdrv_present_readback(client); }
    }
}

static const struct client_surface_funcs iosdrv_client_surface_funcs =
{
    .destroy = iosdrv_client_surface_destroy,
    .detach = iosdrv_client_surface_detach,
    .update = iosdrv_client_surface_update,
    .present = iosdrv_client_surface_present,
};

struct client_surface *iosdrv_CreateClientSurface(HWND hwnd, int pixel_format)
{
    struct iosdrv_client_surface *surface;

    (void)pixel_format;
    if (!(surface = client_surface_create(sizeof(*surface), &iosdrv_client_surface_funcs, hwnd))) return NULL;
    surface->device = [MTLCreateSystemDefaultDevice() retain];
    surface->layer = [[JuiceIOSMetalLayer alloc] init];
    surface->queue = [surface->device newCommandQueue];
    if (!surface->device || !surface->layer || !surface->queue)
    {
        client_surface_release(&surface->client);
        return NULL;
    }
    surface->layer.device = surface->device;
    surface->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    surface->layer.framebufferOnly = NO;
    surface->layer.opaque = YES;
    surface->layer.contentsScale = 1.0;
    surface->layer.maximumDrawableCount = 3;
    surface->layer.allowsNextDrawableTimeout = YES;
    iosdrv_client_surface_update(&surface->client);
    fprintf(stderr, "JUICE_MOLTENVK_CLIENT_SURFACE_READY hwnd=%p device=%s size=%.0fx%.0f\n",
            hwnd, [[surface->device name] UTF8String], surface->layer.drawableSize.width,
            surface->layer.drawableSize.height);
    return &surface->client;
}

static VkResult iosdrv_vulkan_surface_create(struct client_surface *client,
                                             const struct vulkan_instance *instance,
                                             VkSurfaceKHR *handle)
{
    struct iosdrv_client_surface *surface = impl_from_client_surface(client);
    VkMetalSurfaceCreateInfoEXT create_info =
    {
        .sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
        .pNext = NULL,
        .flags = 0,
        .pLayer = surface->layer,
    };
    VkResult result;

    if (!instance->p_vkCreateMetalSurfaceEXT) return VK_ERROR_EXTENSION_NOT_PRESENT;
    result = instance->p_vkCreateMetalSurfaceEXT(instance->host.instance, &create_info, NULL, handle);
    fprintf(stderr, "JUICE_MOLTENVK_SURFACE_CREATE hwnd=%p result=%d host=0x%llx\n",
            client->hwnd, result, result ? 0ull : (unsigned long long)*handle);
    return result;
}

static VkBool32 iosdrv_get_physical_device_presentation_support(struct vulkan_physical_device *device,
                                                                 uint32_t queue)
{
    /* VK_EXT_metal_surface guarantees presentation for every valid family.
     * Still validate the caller's index against the actual physical device. */
    VkQueueFamilyProperties *families;
    uint32_t count = 0, capacity;
    VkBool32 supported;
    if (!device || !device->instance || !device->instance->p_vkGetPhysicalDeviceQueueFamilyProperties) return VK_FALSE;
    device->instance->p_vkGetPhysicalDeviceQueueFamilyProperties(device->host.physical_device, &count, NULL);
    if (!count || count > 4096 || queue >= count) return VK_FALSE;
    capacity = count;
    if (!(families = calloc(capacity, sizeof(*families)))) return VK_FALSE;
    device->instance->p_vkGetPhysicalDeviceQueueFamilyProperties(device->host.physical_device, &count, families);
    supported = count <= capacity && queue < count && families[queue].queueCount != 0;
    free(families);
    return supported;
}

static void iosdrv_map_instance_extensions(struct vulkan_instance_extensions *extensions)
{
    if (extensions->has_VK_KHR_win32_surface) extensions->has_VK_EXT_metal_surface = 1;
    if (extensions->has_VK_EXT_metal_surface) extensions->has_VK_KHR_win32_surface = 1;
}

static void iosdrv_map_device_extensions(struct vulkan_device_extensions *extensions)
{
    (void)extensions;
}

static const struct vulkan_driver_funcs iosdrv_vulkan_driver_funcs =
{
    .p_vulkan_surface_create = iosdrv_vulkan_surface_create,
    .p_get_physical_device_presentation_support = iosdrv_get_physical_device_presentation_support,
    .p_map_instance_extensions = iosdrv_map_instance_extensions,
    .p_map_device_extensions = iosdrv_map_device_extensions,
};

UINT iosdrv_VulkanInit(UINT version, void *vulkan_handle, const struct vulkan_driver_funcs **driver)
{
    if (!driver) return STATUS_INVALID_PARAMETER;
    *driver = NULL;
    if (version != WINE_VULKAN_DRIVER_VERSION)
    {
        ERR("version mismatch, win32u wants %u but wineios has %u\n", version,
            WINE_VULKAN_DRIVER_VERSION);
        return STATUS_INVALID_PARAMETER;
    }
    if (!vulkan_handle || !dlsym(vulkan_handle, "vkCreateMetalSurfaceEXT"))
    {
        ERR("MoltenVK does not expose vkCreateMetalSurfaceEXT\n");
        return STATUS_NOT_SUPPORTED;
    }
    *driver = &iosdrv_vulkan_driver_funcs;
    fprintf(stderr, "JUICE_MOLTENVK_DRIVER_READY version=%u handle=%p\n", version, vulkan_handle);
    return STATUS_SUCCESS;
}
