#include "Interface/Core/JuiceCodegenPolicy.h"
#include <cassert>
#include <cstdio>
#include <thread>
#include <vector>
using FEXCore::Juice::CodeSpan;
using FEXCore::Juice::PlanCodeSpan;
using FEXCore::Juice::RetiredCodeRange;

int main() {
  CodeSpan span;
  assert(PlanCodeSpan(1, 4, 0x10000, 0x4000, span));
  assert(span.Offset == 0x4000 && span.End == 0x8000);
  // A cursor belonging to the old full buffer must not survive replacement.
  assert(!PlanCodeSpan(0xc001, 4, 0x10000, 0x4000, span));
  assert(!span.Offset && !span.End);
  assert(PlanCodeSpan(0, 4, 0x10000, 0x4000, span));
  assert(span.Offset == 0 && span.End == 0x4000);
  assert(!PlanCodeSpan(0, 0xf001, 0xf000, 0x4000, span));
  assert(!PlanCodeSpan(0xc000, 4, 0xf000, 0x4000, span)); // Guard page.
  assert(!PlanCodeSpan(UINT64_MAX, 4, UINT64_MAX, 0x4000, span));
  assert(!PlanCodeSpan(0, UINT64_MAX, UINT64_MAX, 0x4000, span));
  assert(!PlanCodeSpan(0, 1, UINT64_MAX, 3, span));
  assert(!PlanCodeSpan(0, 0, UINT64_MAX, 16, span));
  assert(!PlanCodeSpan(0, 1, 1024, 0, span));
  unsigned checked = 0;
  for (uint64_t alignment : {uint64_t{16}, uint64_t{0x4000}})
  for (uint64_t cursor = 0; cursor < 0x30000; cursor += 31)
  for (uint64_t size : {uint64_t{1}, uint64_t{15}, uint64_t{16}, uint64_t{4095}, uint64_t{16384}, uint64_t{65537}}) {
    bool okay = PlanCodeSpan(cursor, size, 0x2f000, alignment, span);
    if (okay) {
      assert(span.Offset >= cursor && !(span.Offset % alignment));
      assert(span.End <= 0x2f000 && !(span.End % alignment));
      assert(size <= span.End - span.Offset);
      assert(span.Offset - cursor < alignment);
      assert(span.End - span.Offset - size < alignment);
    } else assert(!span.Offset && !span.End);
    ++checked;
  }
  // Packing is enabled only for already-authorized dual aliases. Prove the
  // arithmetic gain without claiming measured runtime speed or FPS.
  unsigned packed = 0, paged = 0;
  for (uint64_t cursor = 0; PlanCodeSpan(cursor, 500, 0x10000, 16, span); cursor = span.Offset + 500) ++packed;
  for (uint64_t cursor = 0; PlanCodeSpan(cursor, 500, 0x10000, 0x4000, span); cursor = span.Offset + 500) ++paged;
  assert(packed == 128 && paged == 4);
  RetiredCodeRange range;
  assert(!range.Contains(0x1000));
  assert(!range.Publish(0, 1) && !range.Publish(1, 0));
  assert(!range.Publish(UINTPTR_MAX - 4, 8));
  assert(range.Publish(0x1000, 0x1000));
  assert(range.Contains(0x1000) && range.Contains(0x1fff));
  assert(!range.Contains(0xfff) && !range.Contains(0x2000));
  std::atomic<bool> start{false};
  std::vector<std::thread> threads;
  for (unsigned writer = 0; writer < 2; ++writer) threads.emplace_back([&, writer] {
    while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
    for (unsigned i = 0; i < 200000; ++i) (void)range.Publish(writer ? 0x4000 : 0x1000, 0x1000);
  });
  for (unsigned reader = 0; reader < 4; ++reader) threads.emplace_back([&] {
    while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
    for (unsigned i = 0; i < 200000; ++i) {
      // Mixed low start / high end from separate generations would match.
      assert(!range.Contains(0x3000));
      assert(!range.Contains(0x5000));
      assert(!range.Contains(0));
    }
  });
  start.store(true, std::memory_order_release);
  for (auto& thread : threads) thread.join();
  printf("JUICE_FEX_CODEGEN_POLICY_OK intervals=%u writers=2 readers=4 iterations=200000\n", checked);
}
