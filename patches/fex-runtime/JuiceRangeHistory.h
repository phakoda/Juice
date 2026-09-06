// Juice-original code, MIT. Bounded advisory history, not a lifetime guarantee.
#pragma once
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace FEXCore::Juice {
template<size_t Count>
class RangeHistory {
  static_assert(Count > 0);
  static_assert(std::atomic<uintptr_t>::is_always_lock_free);
  static_assert(std::atomic<uint64_t>::is_always_lock_free);
  static_assert(std::atomic<size_t>::is_always_lock_free);
  struct Slot {
    std::atomic<uint64_t> Version {};
    std::atomic<uintptr_t> Begin {}, End {};
  };
  std::array<Slot, Count> Slots {};
  std::atomic<size_t> Next {};
public:
  // Do not wait if another writer owns the selected slot. This code can run
  // around signal handling: a signal must never spin on an interrupted writer.
  bool Record(uintptr_t Begin, size_t Size) noexcept {
    if (!Begin || !Size || Size > std::numeric_limits<uintptr_t>::max() - Begin) return false;
    Slot& S = Slots[Next.fetch_add(1, std::memory_order_relaxed) % Count];
    uint64_t Version = S.Version.load(std::memory_order_seq_cst);
    if ((Version & 1) || Version > std::numeric_limits<uint64_t>::max() - 2 ||
        !S.Version.compare_exchange_strong(Version, Version + 1, std::memory_order_seq_cst)) return false;
    // All snapshot atomics are SC deliberately. Relaxed bounds with only an
    // acquire version read do not establish a consistent seqlock snapshot.
    S.Begin.store(Begin, std::memory_order_seq_cst);
    S.End.store(Begin + Size, std::memory_order_seq_cst);
    S.Version.store(Version + 2, std::memory_order_seq_cst);
    return true;
  }

  bool Contains(uintptr_t Address) const noexcept {
    for (const Slot& S : Slots) {
      const uint64_t Before = S.Version.load(std::memory_order_seq_cst);
      if (!Before || (Before & 1)) continue;
      const uintptr_t Begin = S.Begin.load(std::memory_order_seq_cst);
      const uintptr_t End = S.End.load(std::memory_order_seq_cst);
      const uint64_t After = S.Version.load(std::memory_order_seq_cst);
      if (Before == After && Begin && Address >= Begin && Address < End) return true;
    }
    return false;
  }
};
}
