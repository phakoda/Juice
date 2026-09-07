#include "JuiceEmbeddedPolicy.h"
#include <string.h>

int juice_vm_bounds(uintptr_t begin, size_t size, uintptr_t *end)
{
    if (!size || size > UINTPTR_MAX - begin) return 0;
    *end = begin + size;
    return 1;
}
int juice_size_align(size_t value, size_t alignment, size_t *result)
{
    if (!value || !alignment || (alignment & (alignment - 1)) || value > SIZE_MAX - (alignment - 1)) return 0;
    *result = (value + alignment - 1) & ~(alignment - 1);
    return 1;
}
int juice_vm_contains(const JuiceVMSet *set, uintptr_t begin, size_t size)
{
    uintptr_t end;
    if (!juice_vm_bounds(begin, size, &end)) return 0;
    for (size_t i = 0; i < set->count; ++i) {
        if (set->ranges[i].begin > begin) break;
        if (set->ranges[i].begin <= begin && end <= set->ranges[i].end) return 1;
    }
    return 0;
}
int juice_vm_add(JuiceVMSet *set, uintptr_t begin, size_t size)
{
    uintptr_t end;
    if (!juice_vm_bounds(begin, size, &end)) return 0;
    size_t first = 0, last;
    while (first < set->count && set->ranges[first].end < begin) ++first;
    last = first;
    while (last < set->count && set->ranges[last].begin <= end) {
        if (set->ranges[last].begin < begin) begin = set->ranges[last].begin;
        if (set->ranges[last].end > end) end = set->ranges[last].end;
        ++last;
    }
    if (first == last && set->count == JUICE_VM_INTERVALS) return 0;
    memmove(set->ranges + first + 1, set->ranges + last, (set->count - last) * sizeof(set->ranges[0]));
    set->ranges[first] = (JuiceVMInterval){begin, end};
    set->count = set->count - (last - first) + 1;
    return 1;
}
int juice_vm_remove(JuiceVMSet *set, uintptr_t begin, size_t size)
{
    uintptr_t end;
    if (!juice_vm_bounds(begin, size, &end)) return 0;
    /* A split needs an additional slot; reject transactionally before changes. */
    if (set->count == JUICE_VM_INTERVALS)
        for (size_t i = 0; i < set->count; ++i)
            if (set->ranges[i].begin < begin && end < set->ranges[i].end) return 0;
    for (size_t i = 0; i < set->count;) {
        JuiceVMInterval old = set->ranges[i];
        if (old.end <= begin) { ++i; continue; }
        if (old.begin >= end) break;
        if (old.begin < begin && old.end > end) {
            memmove(set->ranges + i + 2, set->ranges + i + 1, (set->count - i - 1) * sizeof(old));
            set->ranges[i].end = begin;
            set->ranges[i + 1] = (JuiceVMInterval){end, old.end};
            ++set->count;
            break;
        }
        if (old.begin < begin) { set->ranges[i].end = begin; ++i; }
        else if (old.end > end) { set->ranges[i].begin = end; break; }
        else {
            memmove(set->ranges + i, set->ranges + i + 1, (set->count - i - 1) * sizeof(old));
            --set->count;
        }
    }
    return 1;
}
