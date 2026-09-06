#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "JuicePEInspect.h"
static void put16(uint8_t *b, uint16_t v) { b[0] = (uint8_t)v; b[1] = (uint8_t)(v >> 8); }
static void put32(uint8_t *b, uint32_t v) { put16(b, (uint16_t)v); put16(b + 2, (uint16_t)(v >> 16)); }
static void image(uint8_t *b, uint16_t machine, bool plus)
{
    memset(b, 0, 1024); b[0] = 'M'; b[1] = 'Z'; put32(b + 60, 64);
    memcpy(b + 64, "PE\0\0", 4); put16(b + 68, machine); put16(b + 70, 1);
    put16(b + 84, plus ? 240 : 224); put16(b + 86, 2);
    uint8_t *o = b + 88; put16(o, plus ? 0x20b : 0x10b);
    put32(o + 16, 0x1000); put32(o + 56, 0x2000); put32(o + 60, 512);
    put16(o + 68, 3); put32(o + (plus ? 108 : 92), 16);
}
int main(void)
{
    alarm(30);
    uint8_t b[1024]; JuicePEInfo out;
    const uint16_t machines[] = {0x14c, 0x8664, 0xaa64, 0xa641, 0xa64e, 0x9999};
    for (size_t i = 0; i < sizeof(machines)/sizeof(machines[0]); i++) {
        image(b, machines[i], machines[i] != 0x14c);
        assert(!JuicePEInspectBytes(b, sizeof(b), &out));
        assert(out.machine == machines[i] && !out.is_dll && !out.managed);
        assert(out.subsystem == 3 && out.sections == 1);
    }
    image(b, 0x14c, false); put16(b + 86, 0x2002);
    put32(b + 88 + 96 + 14 * 8, 0x1000); put32(b + 88 + 96 + 14 * 8 + 4, 72);
    assert(!JuicePEInspectBytes(b, sizeof(b), &out) && out.managed && out.is_dll);
    for (size_t length = 0; length < 512; length++) {
        assert(JuicePEInspectBytes(b, length, &out) == -1 && errno == ENOEXEC);
        assert(out.machine == 0);
    }
    image(b, 0x14c, true); assert(JuicePEInspectBytes(b, sizeof(b), &out) == -1);
    image(b, 0xaa64, false); assert(JuicePEInspectBytes(b, sizeof(b), &out) == -1);
    image(b, 0x8664, true); put32(b + 60, UINT32_MAX); assert(JuicePEInspectBytes(b, sizeof(b), &out) == -1);
    image(b, 0x8664, true); put16(b + 70, 97); assert(JuicePEInspectBytes(b, sizeof(b), &out) == -1);
    image(b, 0x8664, true); put32(b + 88 + 108, UINT32_MAX); assert(JuicePEInspectBytes(b, sizeof(b), &out) == -1);
    image(b, 0x8664, true); put32(b + 88 + 60, 200); assert(JuicePEInspectBytes(b, sizeof(b), &out) == -1);
    image(b, 0x8664, true);
    char name[] = "/tmp/juice-pe-XXXXXX"; int fd = mkstemp(name); assert(fd >= 0); unlink(name);
    assert(write(fd, b, sizeof(b)) == sizeof(b)); assert(lseek(fd, 19, SEEK_SET) == 19);
    assert(!JuicePEInspectFD(fd, &out) && out.machine == 0x8664);
    assert(lseek(fd, 0, SEEK_CUR) == 19); close(fd);
    int p[2]; assert(!pipe(p)); assert(JuicePEInspectFD(p[0], &out) == -1 && errno == EINVAL); close(p[0]); close(p[1]);
    assert(JuicePEInspectBytes(NULL, 1, &out) == -1 && errno == EINVAL);
    assert(JuicePEInspectFD(-1, &out) == -1 && errno == EBADF);
    uint32_t seed = 17;
    for (size_t trial = 0; trial < 20000; trial++) {
        image(b, 0x8664, true);
        for (size_t j = 0; j < 8; j++) { seed = seed * 1664525u + 1013904223u; b[seed % sizeof(b)] ^= (uint8_t)(seed >> 24); }
        (void)JuicePEInspectBytes(b, seed % (sizeof(b) + 1), &out);
    }
    puts("PE_INSPECT_OK architectures=6 truncations=512 mutations=20000");
    return 0;
}
