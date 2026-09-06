#include "JuiceCodePlacement.h"
#include "JuiceRangeHistory.h"
#include <cassert>
#include <cstdio>
#include <thread>
#include <vector>

using namespace FEXCore::Juice;
static bool reference(uintptr_t base,uint64_t usable,uint64_t latest,uint64_t size,uint64_t page) {
  using Wide=__uint128_t;
  const Wide maximum=UINTPTR_MAX;
  if(!base || !size || page<16 || (page&(page-1)) || page>maximum || base%page ||
     (Wide)base+usable>maximum || latest>usable) return false;
  Wide offset=((Wide)latest+page-1)/page*page;
  Wide end=(offset+size+page-1)/page*page;
  return offset<=usable && end<=usable;
}
int main() {
  CodePlacement p;
  assert(PlanCodePlacement(0x10000,0xf000,0,4,0x4000,p));
  assert(p.Offset==0 && p.Begin==0x10000 && p.End==0x14000);
  assert(!PlanCodePlacement(0x10000,0xf000,0xbfff,4,0x4000,p));
  assert(p.Begin==0 && p.End==0);
  // Cache rollover must recompute from the new buffer's current cursor.
  assert(!PlanCodePlacement(0x10000,0xf000,0xf000,4096,0x4000,p));
  assert(PlanCodePlacement(0x40000,0x1f000,0,4096,0x4000,p));
  assert(p.Offset==0 && p.Begin==0x40000 && p.End==0x44000);
  uint64_t seed=0xb03d08a279af31ULL;
  for(unsigned i=0;i<300000;i++) {
    auto random=[&] {seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;return seed;};
    uint64_t page=uint64_t(1)<<(random()%20);
    uint64_t base=random()&~(page-1);
    uint64_t usable=random()%0x100000,latest=random()%0x100000,size=random()%0x40000;
    if(i%7==0) usable=random();
    if(i%11==0) latest=random();
    if(i%13==0) size=random();
    bool ok=PlanCodePlacement(base,usable,latest,size,page,p);
    assert(ok==reference(base,usable,latest,size,page));
    if(ok) {
      assert(p.Offset>=latest && p.Begin%page==0 && p.End%page==0);
      assert(p.Begin>=base && p.End-base<=usable && p.End-p.Begin>=size);
    } else assert(p.Offset==0 && p.Begin==0 && p.End==0);
  }
  RangeHistory<8> history;
  assert(!history.Contains(0));
  assert(!history.Record(0,4096));
  assert(!history.Record(UINTPTR_MAX-3,8));
  assert(!history.Record(0x1000,0));
  for(unsigned i=1;i<=8;i++)assert(history.Record(i*0x1000,0x100));
  for(unsigned i=1;i<=8;i++) {
    assert(history.Contains(i*0x1000));
    assert(history.Contains(i*0x1000+0xff));
    assert(!history.Contains(i*0x1000+0x100));
  }
  assert(history.Record(0x9000,0x100));assert(!history.Contains(0x1000));
  RangeHistory<1> shared;
  std::atomic<bool> run{true};
  std::atomic<unsigned> falsePositives{};
  std::vector<std::thread> readers;
  for(int n=0;n<4;n++) readers.emplace_back([&] {
    while(run.load(std::memory_order_relaxed))
      if(shared.Contains(0x6000)) falsePositives.fetch_add(1,std::memory_order_relaxed);
  });
  std::thread writer([&] {for(unsigned i=0;i<500000;i++) shared.Record(0x1000,0x1000);});
  for(unsigned i=0;i<500000;i++) shared.Record(0x9000,0x1000);
  writer.join();run.store(false,std::memory_order_relaxed);
  for(auto& t:readers)t.join();
  assert(falsePositives.load()==0);
  puts("JUICE_FEX_POLICY_TESTS_OK placements=300000 publications=1000000 readers=4");
}
