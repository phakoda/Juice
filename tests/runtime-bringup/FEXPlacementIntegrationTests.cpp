// Compile the actual patched placement fragment with a mocked allocator/cache.
// This is not an ARM64EC build or an executable-memory authorization test.
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include "JuiceCodePlacement.h"

#define FEX_JUICE_IOS 1
#define LOGMAN_THROW_A_FMT(condition, ...) do { if (!(condition)) throw std::runtime_error("placement failure"); } while (0)
namespace FEXCore::Allocator {
enum ProtectOptions { Read = 1, Write = 2, Exec = 4 };
static uintptr_t LastBegin;
static size_t LastSize;
static unsigned Calls;
static bool Allow = true;
static bool VirtualProtect(void *Address, size_t Size, int Protection) {
  assert(Protection == (Read | Write));
  LastBegin = reinterpret_cast<uintptr_t>(Address);
  LastSize = Size;
  ++Calls;
  return Allow;
}
}
static uint64_t AlignUp(uint64_t Value, uint64_t Alignment) {
  return (Value + Alignment - 1) & ~(Alignment - 1);
}
struct Buffer {
  uint8_t *Ptr;
  uint64_t AllocatedSize;
  bool DualMapped = false;
  uint64_t UsableSize() const { return AllocatedSize - 4096; }
};
struct Backend {
  Buffer First {reinterpret_cast<uint8_t *>(0x10000), 0x10000};
  Buffer Second {reinterpret_cast<uint8_t *>(0x40000), 0x20000};
  Buffer *CurrentCodeBuffer = &First;
  struct {uint64_t LatestOffset = 0;} CodeBuffers;
  Backend *CTX = this;
  void *ThreadState = nullptr;
  uint64_t Cursor = 0;
  unsigned Clears = 0, Alignments = 0;
  void ClearCodeCache(void *) { ++Clears; CurrentCodeBuffer = &Second; CodeBuffers.LatestOffset = 0; }
  void SetBuffer(uint8_t *, uint64_t) {}
  void SetCursorOffset(uint64_t Value) { Cursor = Value; }
  void Align16B() { ++Alignments; Cursor = AlignUp(Cursor, 16); }
  uint64_t GetCursorOffset() const { return Cursor; }
  void PlaceNew(uint64_t TempSize) {
    uintptr_t ProtectStart {}, ProtectEnd {};
#include "placement_new.inc"
  }
  void PlaceLegacy(uint64_t TempSize) {
    uintptr_t ProtectStart {}, ProtectEnd {};
#include "placement_legacy.inc"
  }
};
int main() {
  using namespace FEXCore::Allocator;
  Backend Legacy;
  Legacy.CodeBuffers.LatestOffset = 0xf000;
  Legacy.PlaceLegacy(4096);
  assert(Legacy.Clears == 1 && Legacy.Cursor == 0x10000); // Reproduce stale-offset defect.
  Backend Fixed;
  Fixed.CodeBuffers.LatestOffset = 0xf000;
  Fixed.PlaceNew(4096);
  assert(Fixed.Clears == 1 && Fixed.Cursor == 0);
  assert(LastBegin == 0x40000 && LastSize == 0x4000);
  Backend Guard;
  Guard.CodeBuffers.LatestOffset = 0xc000;
  Guard.PlaceNew(0x3000); // Byte payload fits old buffer, host-page rounding does not.
  assert(Guard.Clears == 1 && Guard.Cursor == 0);
  Backend Normal;
  Normal.CodeBuffers.LatestOffset = 0x1234;
  Normal.PlaceNew(0x2345);
  assert(!Normal.Clears && Normal.Cursor == 0x4000);
  assert(LastBegin == 0x14000 && LastSize == 0x4000);
  Backend Huge;
  unsigned Before = Calls;
  bool Threw = false;
  try { Huge.PlaceNew(UINT64_MAX); } catch (const std::runtime_error &) { Threw = true; }
  assert(Threw && Huge.Clears == 1 && Calls == Before && Huge.Alignments == 0);
  Backend DualMapped;
  DualMapped.CurrentCodeBuffer->DualMapped = true;
  Before = Calls;
  DualMapped.PlaceNew(4096);
  assert(Calls == Before && DualMapped.Alignments == 1);
  Backend Denied;
  Allow = false;
  Threw = false;
  try { Denied.PlaceNew(4096); } catch (const std::runtime_error &) { Threw = true; }
  assert(Threw && Denied.Alignments == 0);
  puts("JUICE_FEX_PLACEMENT_INTEGRATION_OK legacy_defect_reproduced=1 rollover=1 guard=1 overflow=1 dual_map=1 protection_failure=1 mocked_allocator=1");
}
