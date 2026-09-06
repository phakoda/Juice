// Juice-original code, MIT. Checked placement in unpublished JIT pages.
#pragma once
#include <cstddef>
#include <cstdint>
#include <limits>

namespace FEXCore::Juice {
struct CodePlacement {
  uint64_t Offset {};
  uintptr_t Begin {}, End {};
};

// Usable excludes the code buffer's guard page. Round BOTH boundaries so a
// 4 KiB guest guard never gets reopened by a 16 KiB host protection operation.
// This performs arithmetic only; it does not grant executable-memory rights.
inline bool PlanCodePlacement(uintptr_t Base, uint64_t Usable, uint64_t Latest,
                              uint64_t Size, uint64_t PageSize, CodePlacement& Out) noexcept {
  Out = {};
  constexpr auto Max = std::numeric_limits<uintptr_t>::max();
  if (!Base || !Size || PageSize < 16 || (PageSize & (PageSize - 1)) ||
      PageSize > Max || (Base & (PageSize - 1)) || Usable > Max - Base || Latest > Usable) return false;
  const uint64_t Mask = PageSize - 1;
  if (Latest > Max - Mask) return false;
  const uint64_t Offset = (Latest + Mask) & ~Mask;
  if (Offset > Usable || Size > Usable - Offset) return false;
  const uint64_t End = Offset + Size;
  if (End > Max - Mask) return false;
  const uint64_t PageEnd = (End + Mask) & ~Mask;
  if (PageEnd > Usable) return false;
  Out = {Offset, Base + static_cast<uintptr_t>(Offset), Base + static_cast<uintptr_t>(PageEnd)};
  return true;
}
}
