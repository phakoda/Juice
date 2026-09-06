#define _POSIX_C_SOURCE 200809L
#include "JuicePEInspect.h"
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
typedef int (*Reader)(void *, uint64_t, void *, size_t);
static uint16_t u16(const uint8_t *p) { return (uint16_t)(p[0] | (uint16_t)p[1] << 8); }
static uint32_t u32(const uint8_t *p) { return (uint32_t)u16(p) | (uint32_t)u16(p + 2) << 16; }
static int invalid(void) { errno = ENOEXEC; return -1; }
static bool range(uint64_t offset, uint64_t count, uint64_t size)
{ return offset <= size && count <= size - offset; }
static int inspect(Reader read_at, void *context, uint64_t size, JuicePEInfo *out)
{
    if (!out) { errno = EINVAL; return -1; }
    memset(out, 0, sizeof(*out));
    uint8_t dos[64], coff[24], opt[240];
    if (!range(0, sizeof(dos), size)) return invalid();
    if (read_at(context, 0, dos, sizeof(dos))) return -1;
    if (dos[0] != 'M' || dos[1] != 'Z') return invalid();
    uint64_t pe = u32(dos + 60);
    if (pe < sizeof(dos) || !range(pe, sizeof(coff), size)) return invalid();
    if (read_at(context, pe, coff, sizeof(coff))) return -1;
    if (memcmp(coff, "PE\0\0", 4)) return invalid();
    uint16_t machine = u16(coff + 4), sections = u16(coff + 6);
    uint16_t opt_size = u16(coff + 20), flags = u16(coff + 22);
    uint64_t optional = pe + sizeof(coff), table = optional + opt_size;
    if (!sections || sections > 96 || opt_size < 96 ||
        !range(optional, opt_size, size) || !range(table, (uint64_t)sections * 40, size)) return invalid();
    size_t read_size = opt_size < sizeof(opt) ? opt_size : sizeof(opt);
    memset(opt, 0, sizeof(opt));
    if (read_at(context, optional, opt, read_size)) return -1;
    uint16_t magic = u16(opt);
    if (magic != 0x10b && magic != 0x20b) return invalid();
    bool plus = magic == 0x20b;
    uint32_t directory_offset = plus ? 112 : 96;
    if (opt_size < directory_offset) return invalid();
    if ((machine == 0x14c && plus) ||
        ((machine == 0x8664 || machine == 0xaa64 || machine == 0xa641 || machine == 0xa64e) && !plus)) return invalid();
    uint32_t headers = u32(opt + 60), image = u32(opt + 56);
    if (headers < table + (uint64_t)sections * 40 || headers > size || !image || image < headers) return invalid();
    uint32_t directories = u32(opt + directory_offset - 4);
    if (directories > (opt_size - directory_offset) / 8u) return invalid();
    bool managed = false;
    if (directories > 14) {
        size_t clr = directory_offset + 14u * 8u;
        managed = u32(opt + clr) != 0 && u32(opt + clr + 4) != 0;
    }
    *out = (JuicePEInfo){machine, u16(opt + 68), sections, u32(opt + 16), image,
                         plus, (flags & 0x2000) != 0, managed};
    return 0;
}
typedef struct { const uint8_t *bytes; size_t length; } Memory;
static int memory_read(void *context, uint64_t offset, void *out, size_t count)
{
    Memory *m = context;
    if (!range(offset, count, m->length)) return invalid();
    memcpy(out, m->bytes + (size_t)offset, count);
    return 0;
}
int JuicePEInspectBytes(const void *bytes, size_t length, JuicePEInfo *info)
{
    if ((!bytes && length) || !info) {
        if (info) memset(info, 0, sizeof(*info));
        errno = EINVAL; return -1;
    }
    Memory m = {bytes, length};
    return inspect(memory_read, &m, length, info);
}
static int fd_read(void *context, uint64_t offset, void *out, size_t count)
{
    int fd = *(int *)context;
    uint8_t *p = out;
    while (count) {
        ssize_t n = pread(fd, p, count, (off_t)offset);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return -1;
        if (!n) return invalid();
        p += n; offset += (uint64_t)n; count -= (size_t)n;
    }
    return 0;
}
int JuicePEInspectFD(int fd, JuicePEInfo *info)
{
    if (!info) { errno = EINVAL; return -1; }
    memset(info, 0, sizeof(*info));
    struct stat st;
    if (fstat(fd, &st)) return -1;
    if (!S_ISREG(st.st_mode) || st.st_size < 0) { errno = EINVAL; return -1; }
    return inspect(fd_read, &fd, (uint64_t)st.st_size, info);
}
const char *JuicePEMachineName(uint16_t m)
{
    switch (m) {
    case 0x14c: return "x86";
    case 0x8664: return "x86_64";
    case 0xaa64: return "ARM64";
    case 0xa641: return "ARM64EC";
    case 0xa64e: return "ARM64X";
    default: return "unknown";
    }
}
