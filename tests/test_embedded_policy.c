#include "../runtime/embedded/JuiceEmbeddedPolicy.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t random_state = 0x51de570;
static unsigned random_value(void)
{
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
}
int main(void)
{
    JuiceVMSet *set = calloc(1, sizeof(*set));
    JuiceVMSet *before = malloc(sizeof(*before));
    assert(set && before);
    uintptr_t end;
    size_t rounded;
    assert(!juice_vm_bounds(UINTPTR_MAX, 1, &end));
    assert(!juice_vm_bounds(0, 0, &end));
    assert(juice_vm_bounds(UINTPTR_MAX - 1, 1, &end) && end == UINTPTR_MAX);
    assert(!juice_size_align(SIZE_MAX, 16384, &rounded));
    assert(!juice_size_align(1, 3, &rounded));
    assert(!juice_size_align(0, 16384, &rounded));
    assert(juice_size_align(16385, 16384, &rounded) && rounded == 32768);
    unsigned char oracle[512] = {0};
    const uintptr_t base = UINT64_C(0x100000000);
    for (size_t step = 0; step < 100000; ++step) {
        unsigned start = random_value() % 512, length = 1 + random_value() % (512 - start);
        int add = random_value() & 1;
        assert(add ? juice_vm_add(set, base + start, length) : juice_vm_remove(set, base + start, length));
        memset(oracle + start, add, length);
        for (unsigned i = 0; i < 512; ++i)
            assert(juice_vm_contains(set, base + i, 1) == !!oracle[i]);
        for (size_t i = 0; i < set->count; ++i) {
            assert(set->ranges[i].begin < set->ranges[i].end);
            if (i) assert(set->ranges[i - 1].end < set->ranges[i].begin);
        }
        unsigned check = random_value() % 512, count = 1 + random_value() % (512 - check);
        int all = 1;
        for (unsigned i = check; i < check + count; ++i) all &= oracle[i];
        assert(juice_vm_contains(set, base + check, count) == all);
    }
    memset(set, 0, sizeof(*set));
    for (size_t i = 0; i < JUICE_VM_INTERVALS; ++i) assert(juice_vm_add(set, base + i * 8, 4));
    memcpy(before, set, sizeof(*set));
    assert(!juice_vm_add(set, base + JUICE_VM_INTERVALS * 8, 4));
    assert(!memcmp(before, set, sizeof(*set)));
    assert(!juice_vm_remove(set, base + 1, 1)); /* split is transactional at capacity */
    assert(!memcmp(before, set, sizeof(*set)));
    assert(juice_vm_add(set, base, JUICE_VM_INTERVALS * 8));
    assert(set->count == 1);
    assert(juice_vm_remove(set, base, JUICE_VM_INTERVALS * 8));
    assert(set->count == 0);
    free(set); free(before);
    puts("JUICE_EMBEDDED_POLICY_OK operations=100000 membership_checks=51200000 capacity=16384");
    return 0;
}
