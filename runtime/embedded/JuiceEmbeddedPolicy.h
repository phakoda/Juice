#ifndef JUICE_EMBEDDED_POLICY_H
#define JUICE_EMBEDDED_POLICY_H
#include <stddef.h>
#include <stdint.h>

/* All address arithmetic is checked before calling an OS VM primitive. Sorted,
 * disjoint half-open intervals distinguish Wine-owned mappings from host memory. */
#define JUICE_VM_INTERVALS 16384u
typedef struct JuiceVMInterval { uintptr_t begin, end; } JuiceVMInterval;
typedef struct JuiceVMSet { size_t count; JuiceVMInterval ranges[JUICE_VM_INTERVALS]; } JuiceVMSet;
int juice_vm_bounds(uintptr_t begin, size_t size, uintptr_t *end);
int juice_vm_contains(const JuiceVMSet *, uintptr_t begin, size_t size);
int juice_vm_add(JuiceVMSet *, uintptr_t begin, size_t size);
int juice_vm_remove(JuiceVMSet *, uintptr_t begin, size_t size);
int juice_size_align(size_t value, size_t alignment, size_t *result);
#endif
