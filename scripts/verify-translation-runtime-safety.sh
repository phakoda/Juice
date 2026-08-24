#!/usr/bin/env bash
set -euo pipefail

# Reject translated runtimes assembled from the pre-hole-list-safety Wine
# binaries.  Those binaries can corrupt XNU's vm_map hole list after exposing
# the sub-4-GiB Win32 range and have produced a reproducible device panic.
RUNTIME="${1:-}"
test -n "$RUNTIME" || {
  echo "usage: $0 /path/to/Grape-X64" >&2
  exit 2
}

LOADER="$RUNTIME/build/wine-ios/loader/wine"
NTDLL="$RUNTIME/build/wine-ios/dlls/ntdll/ntdll.so"
PE_NTDLL="$RUNTIME/runtime/lib/wine/aarch64-windows/ntdll.dll"
PE_KERNELBASE="$RUNTIME/runtime/lib/wine/aarch64-windows/kernelbase.dll"
PE_USER32="$RUNTIME/runtime/lib/wine/aarch64-windows/user32.dll"
HELPER="$RUNTIME/tools/juice-lowva-helper"

require_marker()
{
  local path="$1" marker="$2" description="$3"
  test -s "$path" || {
    echo "Unsafe translated runtime: missing $description: $path" >&2
    exit 3
  }
  # Do not use grep -q here.  With pipefail enabled, grep exits as soon as it
  # finds the marker and a large strings(1) producer can then receive SIGPIPE,
  # turning a successful match into a false packaging failure.
  LC_ALL=C strings "$path" | grep -F "$marker" >/dev/null || {
    echo "Unsafe translated runtime: $description lacks required marker '$marker': $path" >&2
    echo "Rebuild Wine and re-run assemble-runtime.sh plus assemble-x86_64-runtime.sh." >&2
    exit 3
  }
}

# The loader must disable XNU's hole-list allocator before the helper lowers
# vm_map::min_offset.  The helper protocol token prevents pairing a new loader
# with the old unchecked helper.  The ntdll marker proves MAP_FIXED low-range
# probes are gated on the successful bootstrap handshake.
require_marker "$LOADER" "JUICE_LOWVA_HOLELIST_OK" "Wine loader"
require_marker "$LOADER" "JUICE_LOWVA_ATOMIC_RESERVE_OK" "Wine loader atomic low-VA reservation"
require_marker "$LOADER" "JUICE_LOWVA_WIN32_2G_RESERVE_OK" "Wine loader full Win32 2 GiB reservation"
require_marker "$HELPER" "holes-disabled-v1" "low-VA helper"
require_marker "$NTDLL" "JUICE_LOWVA_READY" "Wine ntdll Unix library"
# Wine's ARM64EC builtins must recover x18/TEB through the Unix pthread-TLS
# accessor.  Requiring both the ntdll export and representative core/UI imports
# prevents an old signal-storm PE set from being paired with a new loader.
require_marker "$PE_NTDLL" "NtWineRestoreCurrentTeb" "Wine PE ntdll TEB recovery export"
require_marker "$PE_KERNELBASE" "NtWineRestoreCurrentTeb" "Wine PE kernelbase TEB recovery import"
require_marker "$PE_USER32" "NtWineRestoreCurrentTeb" "Wine PE user32 TEB recovery import"

echo "JUICE_TRANSLATION_RUNTIME_SAFETY_OK runtime=$RUNTIME protocol=holes-disabled-v4-teb-tls-recovery"
