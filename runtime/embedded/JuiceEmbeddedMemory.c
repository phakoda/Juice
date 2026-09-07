#define _DARWIN_C_SOURCE 1
#include "JuiceEmbeddedRuntime.h"
#include "JuiceEmbeddedPolicy.h"
#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <dlfcn.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/vm_region.h>
#include <sys/sysctl.h>
#include <libkern/OSCacheControl.h>
#endif

static pthread_mutex_t vm_lock = PTHREAD_MUTEX_INITIALIZER;
static JuiceVMSet owned, published;
static _Atomic int jit_ready;
static void *arena_write, *arena_execute;
static size_t arena_used;
struct allocation { void *write, *execute; size_t size; int freed; };
static struct allocation jit_allocations[64];
static size_t jit_allocation_count;

static void lock_vm(sigset_t *previous)
{
    sigset_t set; sigemptyset(&set);
    sigaddset(&set, SIGUSR1); sigaddset(&set, SIGUSR2); sigaddset(&set, SIGQUIT);
    pthread_sigmask(SIG_BLOCK, &set, previous);
    pthread_mutex_lock(&vm_lock);
}
static void unlock_vm(const sigset_t *previous)
{
    pthread_mutex_unlock(&vm_lock);
    pthread_sigmask(SIG_SETMASK, previous, NULL);
}
static size_t host_page(void) { long n = sysconf(_SC_PAGESIZE); return n > 0 ? (size_t)n : 16384; }
static int span(void *base, size_t length, size_t *rounded)
{
    uintptr_t end;
    size_t page = host_page();
    return !((uintptr_t)base & (page - 1)) && juice_size_align(length, page, rounded) &&
           juice_vm_bounds((uintptr_t)base, *rounded, &end) && (uintptr_t)base >= UINT64_C(0x100000000);
}

#if defined(__APPLE__) && defined(__aarch64__)
__attribute__((naked, noinline, optnone))
static void *prepare_region(void *address __attribute__((unused)), size_t size __attribute__((unused)))
{ __asm__ volatile("mov x16, #1\nbrk #0xf00d\nret\n"); }
__attribute__((naked, noinline, optnone))
static void detach_debugger(void)
{ __asm__ volatile("mov x16, #0\nbrk #0xf00d\nret\n"); }

static int debug_authorized(int require_attached)
{
    int (*csops_fn)(pid_t, unsigned int, void *, size_t) = dlsym(RTLD_DEFAULT, "csops");
    unsigned int flags = 0;
    if (!csops_fn || csops_fn(getpid(), 0, &flags, sizeof(flags)) || !(flags & 0x10000000u)) return 0;
    if (require_attached) {
        struct kinfo_proc info = {0}; size_t size = sizeof(info);
        int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
        if (sysctl(mib, 4, &info, &size, NULL, 0) || size != sizeof(info) || !(info.kp_proc.p_flag & P_TRACED)) return 0;
    }
    return 1;
}
static int protections(void *base, size_t length, vm_prot_t required, vm_prot_t forbidden)
{
    vm_address_t address = (vm_address_t)base;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t error = vm_region_64(mach_task_self(), &address, &size,
        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
    if (object) mach_port_deallocate(mach_task_self(), object);
    return error == KERN_SUCCESS && address <= (vm_address_t)base &&
        (vm_address_t)base - address <= size && length <= size - ((vm_address_t)base - address) &&
        (info.protection & required) == required && !(info.protection & forbidden);
}
static void flush_code(void *write, void *execute, size_t length)
{
    sys_dcache_flush(write, length);
    sys_icache_invalidate(execute, length);
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
}
#endif

int juice_runtime_jit_ready(void) { return atomic_load_explicit(&jit_ready, memory_order_acquire); }
int juice_runtime_prepare_jit(int universal)
{
    if (juice_runtime_jit_ready()) return 0;
#if defined(__APPLE__) && defined(__aarch64__)
    /* A URL completion or an entitlement is not debugger authorization. The
     * universal breakpoint is never executed without observing a live attach. */
    if (!debug_authorized(universal)) return EACCES;
    sigset_t previous; lock_vm(&previous);
    if (juice_runtime_jit_ready()) { unlock_vm(&previous); return 0; }
    const size_t size = JUICE_EMBEDDED_ARENA_BYTES;
    void *rx = universal ? prepare_region(NULL, size) :
        mmap(NULL, size, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
    size_t rounded;
    if (!rx || rx == MAP_FAILED || !span(rx, size, &rounded) ||
        !protections(rx, size, VM_PROT_READ | VM_PROT_EXECUTE, VM_PROT_WRITE)) {
        if (universal && debug_authorized(1)) detach_debugger();
        unlock_vm(&previous); return EACCES;
    }
    vm_address_t writable = 0;
    vm_prot_t current = 0, maximum = 0;
    kern_return_t result = vm_remap(mach_task_self(), &writable, size, 0, VM_FLAGS_ANYWHERE,
        mach_task_self(), (vm_address_t)rx, FALSE, &current, &maximum, VM_INHERIT_NONE);
    if (result == KERN_SUCCESS)
        result = vm_protect(mach_task_self(), writable, size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (result != KERN_SUCCESS || !writable ||
        !protections((void *)writable, size, VM_PROT_READ | VM_PROT_WRITE, VM_PROT_EXECUTE)) {
        if (writable) vm_deallocate(mach_task_self(), writable, size);
        vm_deallocate(mach_task_self(), (vm_address_t)rx, size);
        if (universal && debug_authorized(1)) detach_debugger();
        unlock_vm(&previous); return EACCES;
    }
    /* Reserve one page for a deterministic write-alias -> executable-alias
     * probe. This is a real instruction execution, not a marker-only test. */
    const uint32_t code[] = {0x52800540u, 0xd65f03c0u}; /* mov w0,#42 ; ret */
    memcpy((void *)writable, code, sizeof(code));
    flush_code((void *)writable, rx, sizeof(code));
    if (universal) detach_debugger();
    int answer = ((int (*)(void))rx)();
    if (answer != 42) {
        vm_deallocate(mach_task_self(), writable, size);
        vm_deallocate(mach_task_self(), (vm_address_t)rx, size);
        unlock_vm(&previous); return EIO;
    }
    arena_write = (void *)writable; arena_execute = rx; arena_used = 65536;
    atomic_store_explicit(&jit_ready, 1, memory_order_release);
    unlock_vm(&previous);
    return 0;
#else
    (void)universal; return ENOTSUP;
#endif
}

static int arena_allocate_locked(size_t size, void **write, void **execute)
{
    size_t aligned;
    if (!juice_runtime_jit_ready() || !juice_size_align(size, 65536, &aligned) ||
        aligned > JUICE_EMBEDDED_ARENA_BYTES - arena_used) return ENOMEM;
    *write = (char *)arena_write + arena_used;
    *execute = (char *)arena_execute + arena_used;
    arena_used += aligned;
    return 0;
}
int juice_runtime_jit_allocate(void **write, void **execute, size_t size)
{
    if (!write || !execute || write == execute || !size) return EINVAL;
    *write = NULL; *execute = NULL;
    sigset_t previous; lock_vm(&previous);
    int error = jit_allocation_count == 64 ? ENOMEM : arena_allocate_locked(size, write, execute);
    if (!error) jit_allocations[jit_allocation_count++] = (struct allocation){*write, *execute, size, 0};
    unlock_vm(&previous);
    return error;
}
int juice_runtime_jit_free(void *write, void *execute, size_t size)
{
    sigset_t previous; lock_vm(&previous);
    int error = EINVAL;
    for (size_t i = 0; i < jit_allocation_count; ++i)
        if (!jit_allocations[i].freed && jit_allocations[i].write == write &&
            jit_allocations[i].execute == execute && jit_allocations[i].size == size) {
            /* Quarantine until this app process ends. Never recycle code pages
             * beneath an executing translated thread or unmap the shared arena. */
            jit_allocations[i].freed = 1; error = 0; break;
        }
    unlock_vm(&previous); return error;
}
int juice_runtime_jit_seal(void)
{
    /* External debugger detach was completed before any Wine code started. FEX
     * receives slices of that prepared arena, not a new breakpoint handoff. */
    return juice_runtime_jit_ready() ? 0 : EACCES;
}

void *juice_runtime_mmap(void *address, size_t length, int prot, int flags, int fd, off_t offset)
{
    size_t size;
    if (!juice_size_align(length, host_page(), &size)) { errno = EINVAL; return MAP_FAILED; }
    const int try_fixed = !!(flags & 0x40000000);
    flags &= ~0x40000000;
    sigset_t previous; lock_vm(&previous);
    if ((flags & MAP_FIXED) && (!juice_vm_contains(&owned, (uintptr_t)address, size) ||
                               (uintptr_t)address < UINT64_C(0x100000000))) {
        unlock_vm(&previous); errno = EPERM; return MAP_FAILED;
    }
    if (owned.count >= JUICE_VM_INTERVALS - 2) { unlock_vm(&previous); errno = ENOMEM; return MAP_FAILED; }
    /* PE relocation and import fixups happen while NX. Final RX publication is
     * handled below; no anonymous RWX allocation is attempted on stock iOS. */
    void *mapped = mmap(address, size, prot & ~PROT_EXEC, flags, fd, offset);
    if (mapped != MAP_FAILED && ((try_fixed && mapped != address) || (uintptr_t)mapped < UINT64_C(0x100000000))) {
        munmap(mapped, size); mapped = MAP_FAILED; errno = EEXIST;
    }
    if (mapped != MAP_FAILED) {
        juice_vm_remove(&published, (uintptr_t)mapped, size);
        if (!juice_vm_add(&owned, (uintptr_t)mapped, size)) {
            munmap(mapped, size); mapped = MAP_FAILED; errno = ENOMEM;
        }
    }
    int saved = errno; unlock_vm(&previous); errno = saved;
    return mapped;
}
int juice_runtime_munmap(void *address, size_t length)
{
    size_t size;
    if (!span(address, length, &size)) { errno = EINVAL; return -1; }
    sigset_t previous; lock_vm(&previous);
    if (!juice_vm_contains(&owned, (uintptr_t)address, size) || owned.count >= JUICE_VM_INTERVALS - 1 ||
        published.count >= JUICE_VM_INTERVALS - 1) {
        unlock_vm(&previous); errno = EPERM; return -1;
    }
    int result = munmap(address, size), saved = errno;
    if (!result) {
        juice_vm_remove(&owned, (uintptr_t)address, size);
        juice_vm_remove(&published, (uintptr_t)address, size);
    }
    unlock_vm(&previous); errno = saved; return result;
}
int juice_runtime_mprotect(void *address, size_t length, int prot)
{
    size_t size;
    if (!span(address, length, &size) || prot & ~(PROT_READ | PROT_WRITE | PROT_EXEC)) { errno = EINVAL; return -1; }
    if ((prot & (PROT_WRITE | PROT_EXEC)) == (PROT_WRITE | PROT_EXEC)) { errno = EACCES; return -1; }
    sigset_t previous; lock_vm(&previous);
    if (!juice_vm_contains(&owned, (uintptr_t)address, size) || published.count >= JUICE_VM_INTERVALS - 2) {
        unlock_vm(&previous); errno = EPERM; return -1;
    }
    int result = -1, saved = ENOTSUP;
    if (prot & PROT_EXEC) {
#if defined(__APPLE__) && defined(__aarch64__)
        void *write = NULL, *execute = NULL;
        saved = arena_allocate_locked(size, &write, &execute);
        if (!saved) {
            /* vm_read_overwrite cannot fault UIKit or invoke a Wine signal
             * handler while holding this lock if source permissions are wrong. */
            vm_size_t copied = 0;
            kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)address,
                size, (vm_address_t)write, &copied);
            if (kr == KERN_SUCCESS && copied == size) {
                flush_code(write, execute, size);
                vm_address_t target = (vm_address_t)address;
                vm_prot_t current = 0, maximum = 0;
                kr = vm_remap(mach_task_self(), &target, size, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                    mach_task_self(), (vm_address_t)execute, FALSE, &current, &maximum, VM_INHERIT_NONE);
                if (kr == KERN_SUCCESS && target == (vm_address_t)address) {
                    result = vm_protect(mach_task_self(), target, size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS ? 0 : -1;
                    if (!result) juice_vm_add(&published, (uintptr_t)address, size);
                }
            }
            saved = result ? EACCES : 0;
        }
#endif
    } else if (prot & PROT_WRITE) {
        result = 0;
        /* Previously published code can become writable only by replacing its
         * app-owned alias with fresh NX storage. The prepared RX arena remains
         * immutable. A later execute transition publishes another bounded slice. */
        size_t page = host_page();
        for (size_t offset = 0; offset < size; offset += page) {
            void *base = (char *)address + offset;
            if (juice_vm_contains(&published, (uintptr_t)base, page)) {
                void *copy = malloc(page);
                if (!copy) { result = -1; saved = ENOMEM; break; }
#ifdef __APPLE__
                vm_size_t copied = 0;
                int readable = vm_read_overwrite(mach_task_self(), (vm_address_t)base, page,
                    (vm_address_t)copy, &copied) == KERN_SUCCESS && copied == page;
#else
                int readable = 0;
#endif
                if (!readable) { free(copy); result = -1; saved = EACCES; break; }
                if (mmap(base, page, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0) == MAP_FAILED) {
                    free(copy); result = -1; saved = errno; break;
                }
                memcpy(base, copy, page); free(copy);
                juice_vm_remove(&published, (uintptr_t)base, page);
            }
            if (mprotect(base, page, prot)) { result = -1; saved = errno; break; }
        }
    } else { result = mprotect(address, size, prot); saved = errno; }
    unlock_vm(&previous); if (result) errno = saved; return result;
}
int juice_runtime_copy_guest(void *destination, const void *source, size_t size, int write_guest)
{
    if (!size) return 1;
    sigset_t previous; lock_vm(&previous);
    const void *guest = write_guest ? destination : source;
    int okay = size <= 64u * 1024u * 1024u && juice_vm_contains(&owned, (uintptr_t)guest, size);
#ifdef __APPLE__
    if (okay) {
        vm_size_t copied = 0;
        okay = vm_read_overwrite(mach_task_self(), (vm_address_t)source, size,
                                (vm_address_t)destination, &copied) == KERN_SUCCESS && copied == size;
    }
#else
    okay = 0;
#endif
    unlock_vm(&previous); return okay;
}
