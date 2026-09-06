/* Compiles the production queue-query body, with only the Vulkan enumeration
 * boundary mocked. This is not a GPU or driver-conformance test. */
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <assert.h>
#include <stdio.h>
#define VK_FALSE 0u
#define VK_TRUE 1u
#define VK_QUEUE_GRAPHICS_BIT 1u
typedef uint32_t VkBool32;
typedef struct {uint32_t queueFlags,queueCount;} VkQueueFamilyProperties;
struct vulkan_instance {void (*p_vkGetPhysicalDeviceQueueFamilyProperties)(void *,uint32_t *,VkQueueFamilyProperties *);};
struct vulkan_physical_device {struct vulkan_instance *instance;struct {void *physical_device;} host;};
static unsigned calls,returnedCount,fillCount,selectedFlags,selectedCount;
static bool failAllocation;
static void *test_calloc(size_t n,size_t size) {return failAllocation?NULL:calloc(n,size);}
static void enumerate(void *device,uint32_t *count,VkQueueFamilyProperties *props)
{
    assert(device==(void *)(uintptr_t)0x1234);++calls;
    if(!props) {*count=returnedCount;return;}
    for(uint32_t i=0;i<*count;i++)props[i]=(VkQueueFamilyProperties){selectedFlags,selectedCount};
    *count=fillCount;
}
#define calloc test_calloc
#include "presentation_query.inc"
#undef calloc
int main(void)
{
    struct vulkan_instance instance={enumerate};
    struct vulkan_physical_device device={&instance,{(void *)(uintptr_t)0x1234}};
    returnedCount=fillCount=2;selectedFlags=VK_QUEUE_GRAPHICS_BIT;selectedCount=1;
    assert(iosdrv_get_physical_device_presentation_support(&device,0)==VK_TRUE);
    assert(calls==2);calls=0;
    assert(iosdrv_get_physical_device_presentation_support(&device,2)==VK_FALSE);
    assert(calls==1);calls=0;
    selectedFlags=2;assert(!iosdrv_get_physical_device_presentation_support(&device,0));
    selectedFlags=1;selectedCount=0;assert(!iosdrv_get_physical_device_presentation_support(&device,0));
    selectedCount=1;fillCount=0;assert(!iosdrv_get_physical_device_presentation_support(&device,0));
    fillCount=3;assert(!iosdrv_get_physical_device_presentation_support(&device,0));
    fillCount=2;failAllocation=true;assert(!iosdrv_get_physical_device_presentation_support(&device,0));
    failAllocation=false;returnedCount=257;assert(!iosdrv_get_physical_device_presentation_support(&device,0));
    returnedCount=0;assert(!iosdrv_get_physical_device_presentation_support(&device,0));
    instance.p_vkGetPhysicalDeviceQueueFamilyProperties=NULL;
    assert(!iosdrv_get_physical_device_presentation_support(&device,0));
    puts("JUICE_PRESENTATION_QUERY_TESTS_OK mocked_enumeration=1");
}
