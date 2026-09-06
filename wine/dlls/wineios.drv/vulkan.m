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
#include "graphics_layout.h"

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
    pthread_mutex_t present_lock;
    BOOL present_lock_ready, detached;
};

/* Logical readback-byte budget, independent of the UIKit receiver's budget.
 * Includes both old and replacement buffers during allocation. */
static pthread_mutex_t readback_budget_lock = PTHREAD_MUTEX_INITIALIZER;
static size_t readback_budget_used;
static void iosdrv_release_readback_budget(NSUInteger bytes)
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
    /* client_surface's last reference owns teardown; no submitted async
     * readbacks outlive it. Break the drawable/layer ownership chain explicitly. */
    [surface->layer clearLastDrawable];
    [surface->readback release];
    iosdrv_release_readback_budget(surface->readback_size);
    if (surface->present_lock_ready) pthread_mutex_destroy(&surface->present_lock);
    [surface->queue release];
    [surface->layer release];
    [surface->device release];
}

static void iosdrv_client_surface_detach(struct client_surface *client)
{
    struct iosdrv_client_surface *surface = impl_from_client_surface(client);
    if (!surface->present_lock_ready) return;
    pthread_mutex_lock(&surface->present_lock);
    surface->detached = TRUE;
    surface->layer.hidden = YES;
    [surface->layer clearLastDrawable];
    pthread_mutex_unlock(&surface->present_lock);
}

static void iosdrv_client_surface_update(struct client_surface *client)
{
    struct iosdrv_client_surface *surface = impl_from_client_surface(client);
    if (!surface->present_lock_ready) return;
    int64_t width = (int64_t)client->monitor_rect.right - client->monitor_rect.left;
    int64_t height = (int64_t)client->monitor_rect.bottom - client->monitor_rect.top;
    struct ios_graphics_layout layout;
    if (width < 1) width = 1;
    if (height < 1) height = 1;
    if (!ios_graphics_layout(width, height, 256, &layout))
    {
        WARN("rejecting oversized Metal drawable for %s\n", debugstr_client_surface(client));
        return;
    }
    CGSize size = CGSizeMake(width, height);
    pthread_mutex_lock(&surface->present_lock);
    if (!surface->detached && !CGSizeEqualToSize(surface->layer.drawableSize, size))
    {
        surface->layer.bounds = CGRectMake(0, 0, width, height);
        surface->layer.drawableSize = size;
        TRACE("resized %s Metal surface to %lldx%lld\n", debugstr_client_surface(client),
              (long long)width, (long long)height);
    }
    pthread_mutex_unlock(&surface->present_lock);
}

static BOOL iosdrv_prepare_readback(struct iosdrv_client_surface *surface, NSUInteger width, NSUInteger height)
{
    struct ios_graphics_layout layout;
    if (!ios_graphics_layout(width, height, 256, &layout)) return FALSE;
    if (surface->readback && surface->readback_size >= layout.size &&
        surface->readback_stride == layout.stride) return TRUE;

    pthread_mutex_lock(&readback_budget_lock);
    BOOL reserved = ios_graphics_budget_reserve(&readback_budget_used, layout.size);
    pthread_mutex_unlock(&readback_budget_lock);
    if (!reserved) return FALSE;
    id<MTLBuffer> replacement = [surface->device newBufferWithLength:layout.size
                                                          options:MTLResourceStorageModeShared];
    if (!replacement)
    {
        iosdrv_release_readback_budget(layout.size);
        return FALSE; /* Leave the previous allocation intact on failure. */
    }
    [surface->readback release];
    iosdrv_release_readback_budget(surface->readback_size);
    surface->readback = replacement;
    surface->readback_size = layout.size;
    surface->readback_stride = layout.stride;
    return TRUE;
}

static enum ios_pixel_format iosdrv_readback_format(MTLPixelFormat format)
{
    switch (format)
    {
    case MTLPixelFormatBGRA8Unorm:
    case MTLPixelFormatBGRA8Unorm_sRGB: return IOS_PIXEL_BGRA8;
    case MTLPixelFormatRGBA8Unorm:
    case MTLPixelFormatRGBA8Unorm_sRGB: return IOS_PIXEL_RGBA8;
    case MTLPixelFormatRGB10A2Unorm: return IOS_PIXEL_RGB10A2;
    case MTLPixelFormatBGR10A2Unorm: return IOS_PIXEL_BGR10A2;
    default: return IOS_PIXEL_UNSUPPORTED;
    }
}

static void iosdrv_client_surface_present(struct client_surface *client, HDC hdc)
{
    struct iosdrv_client_surface *surface = impl_from_client_surface(client);
    if (!surface->present_lock_ready) return;
    pthread_mutex_lock(&surface->present_lock);
    id<CAMetalDrawable> drawable = surface->detached ? nil : [surface->layer copyLastDrawable];
    id<MTLTexture> texture = drawable.texture;
    id<MTLCommandBuffer> command;
    id<MTLBlitCommandEncoder> blit;
    NSUInteger width, height, wire_stride;
    RECT dirty;
    enum ios_pixel_format format;

    (void)hdc;
    if (!drawable || !texture) goto done;
    format = iosdrv_readback_format(texture.pixelFormat);
    if (!format || texture.sampleCount != 1 || texture.textureType != MTLTextureType2D ||
        texture.framebufferOnly)
    {
        WARN("unsupported readback texture format=%lu samples=%lu type=%lu\n",
             (unsigned long)texture.pixelFormat, (unsigned long)texture.sampleCount,
             (unsigned long)texture.textureType);
        goto done;
    }
    width = texture.width;
    height = texture.height;
    if (!width || !height || !iosdrv_prepare_readback(surface, width, height)) goto done;

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
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted)
    {
        ERR("Metal readback failed for %s: %s\n", debugstr_client_surface(client),
            [[command.error description] UTF8String]);
        goto done;
    }

    /* Preserve the native BGRA fast path: the receiver already accepts padded
     * rows, so a full-frame CPU compaction would add unnecessary memory traffic.
     * Other supported formats convert in place without a second allocation. */
    wire_stride = surface->readback_stride;
    if (format != IOS_PIXEL_BGRA8)
    {
        if (!ios_graphics_pack_bgra(surface->readback.contents, surface->readback_size,
                                   width, height, surface->readback_stride, format)) goto done;
        wire_stride = width * 4u;
    }
    SetRect(&dirty, 0, 0, (INT)width, (INT)height);
    ios_ipc_present(client->hwnd, surface->readback.contents, (unsigned int)width,
                    (unsigned int)height, (unsigned int)wire_stride, &dirty);
    if (surface->present_count++ < 3)
        fprintf(stderr, "JUICE_MOLTENVK_PRESENT_OK hwnd=%p width=%lu height=%lu stride=%lu frame=%u\n",
                client->hwnd, (unsigned long)width, (unsigned long)height,
                (unsigned long)wire_stride, surface->present_count);

done:
    [drawable release];
    pthread_mutex_unlock(&surface->present_lock);
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
    if (pthread_mutex_init(&surface->present_lock, NULL))
    {
        client_surface_release(&surface->client);
        return NULL;
    }
    surface->present_lock_ready = TRUE;
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
    VkQueueFamilyProperties *properties;
    uint32_t count = 0, capacity;
    VkBool32 supported = VK_FALSE;
    const struct vulkan_instance *instance = device->instance;
    if (!instance->p_vkGetPhysicalDeviceQueueFamilyProperties) return VK_FALSE;
    instance->p_vkGetPhysicalDeviceQueueFamilyProperties(device->host.physical_device, &count, NULL);
    /* A bounded failure is preferable to advertising a fabricated queue. */
    if (!count || count > 256 || queue >= count) return VK_FALSE;
    capacity = count;
    if (!(properties = calloc(capacity, sizeof(*properties)))) return VK_FALSE;
    instance->p_vkGetPhysicalDeviceQueueFamilyProperties(device->host.physical_device, &count, properties);
    if (count <= capacity && queue < count)
        supported = properties[queue].queueCount && (properties[queue].queueFlags & VK_QUEUE_GRAPHICS_BIT);
    free(properties);
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
