#ifndef JUICE_PE_INSPECT_H
#define JUICE_PE_INSPECT_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef struct {
    uint16_t machine, subsystem, sections;
    uint32_t entry_rva, image_size;
    bool pe32_plus, is_dll, managed;
} JuicePEInfo;
/* Structural preflight, NOT authentication or a complete Windows loader.
 * Returns 0 or -1 with errno; output is zeroed on failure. No allocation,
 * unaligned reads, whole-file mapping, or shared descriptor seek state. */
int JuicePEInspectBytes(const void *bytes, size_t length, JuicePEInfo *info);
int JuicePEInspectFD(int fd, JuicePEInfo *info);
const char *JuicePEMachineName(uint16_t machine);
#endif
