#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

required=(
  app/JuiceStikDebugJIT.m
  patches/fex-stikdebug-jit.patch
  patches/fex-stikdebug-lifecycle.patch
  patches/wine-stikdebug-jit.patch
  patches/wine-stikdebug-lifecycle.patch
  scripts/apply-wine-stikdebug-jit.sh
  scripts/fetch-fex-linux.sh
  scripts/verify-fex-patch.sh
)
for path in "${required[@]}"; do
  test -s "$ROOT/$path" || { echo "Missing StikDebug JIT source: $path" >&2; exit 2; }
done

bash -n \
  "$ROOT/scripts/apply-wine-stikdebug-jit.sh" \
  "$ROOT/scripts/fetch-fex-linux.sh" \
  "$ROOT/scripts/verify-fex-patch.sh"

# Parse the hand-edited unified diffs without requiring an FEX checkout.
# --recount derives hunk sizes from the actual patch lines while still rejecting
# malformed syntax such as incomplete hunks or a missing terminal newline.
git -C "$ROOT" apply --recount --numstat "$ROOT/patches/fex-stikdebug-jit.patch" >/dev/null
git -C "$ROOT" apply --recount --numstat "$ROOT/patches/fex-stikdebug-lifecycle.patch" >/dev/null
git -C "$ROOT" apply --recount --numstat "$ROOT/patches/wine-stikdebug-lifecycle.patch" >/dev/null

# Verify the Wine overlays against either a clean source checkout or a source
# tree that has already been prepared for an incremental build.
"$ROOT/scripts/verify-wine-patch.sh"

python3 - "$ROOT/config/Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as handle:
    info = plistlib.load(handle)
schemes = set(info.get("LSApplicationQueriesSchemes", []))
missing = {"stikdebug", "stikjit"} - schemes
if missing:
    raise SystemExit(f"Info.plist is missing StikDebug query schemes: {sorted(missing)}")
print("JUICE_STIKDEBUG_INFO_PLIST_OK")
PY

app="$ROOT/app/JuiceStikDebugJIT.m"
grep -Fq 'POSIX_SPAWN_START_SUSPENDED' "$app"
grep -Fq '0x0080' "$app"
grep -Fq 'CS_DEBUGGED' "$app"
grep -Fq 'JUICE_STIKDEBUG_JIT=1' "$app"
grep -Fq 'JUICE_STIKDEBUG_TXM=1' "$app"
grep -Fq 'Ap,TrustedExecutionMonitor.img4' "$app"
grep -Fq 'queryItemWithName:@"pid"' "$app"
grep -Fq 'queryItemWithName:@"script-name" value:@"universal.js"' "$app"
grep -Fq 'get-task-allow' "$app"
grep -Fq 'JuiceStikDebugJIT.m' "$ROOT/scripts/build-app.sh"
grep -Fq 'stikdebug-wine:' "$ROOT/Makefile"

grep -Fq 'NtWineAllocateJitMemory' "$ROOT/patches/wine-stikdebug-jit.patch"
grep -Fq 'NtWineFreeJitMemory' "$ROOT/patches/wine-stikdebug-jit.patch"
grep -Fq 'vm_remap' "$ROOT/patches/wine-stikdebug-jit.patch"
grep -Fq 'VM_PROT_READ | VM_PROT_WRITE' "$ROOT/patches/wine-stikdebug-jit.patch"
grep -Fq 'set_arm64ec_range' "$ROOT/patches/wine-stikdebug-jit.patch"
grep -Fq 'juice_break_mark_jit_mapping' "$ROOT/patches/wine-stikdebug-jit.patch"
grep -Fq 'juice_break_get_jit_mapping' "$ROOT/patches/wine-stikdebug-jit.patch"
grep -Fq 'brk #0x3caf' "$ROOT/patches/wine-stikdebug-lifecycle.patch"
grep -Fq 'juice_jit_allocation_sealed' "$ROOT/patches/wine-stikdebug-lifecycle.patch"
grep -Fq 'STATUS_ACCESS_DENIED' "$ROOT/patches/wine-stikdebug-lifecycle.patch"

grep -Fq 'WritablePtr' "$ROOT/patches/fex-stikdebug-jit.patch"
grep -Fq 'JuiceAllocateJITMapping' "$ROOT/patches/fex-stikdebug-jit.patch"
grep -Fq 'NtWineAllocateJitMemory' "$ROOT/patches/fex-stikdebug-jit.patch"
grep -Fq 'NtWineFreeJitMemory' "$ROOT/patches/fex-stikdebug-jit.patch"
grep -Fq 'WritableCopyStart' "$ROOT/patches/fex-stikdebug-jit.patch"
grep -Fq 'ClearICache(CopyStart, TempSize)' "$ROOT/patches/fex-stikdebug-jit.patch"
grep -Fq 'ClearICache(JITMapping.Executable, MAX_DISPATCHER_CODE_SIZE)' "$ROOT/patches/fex-stikdebug-jit.patch"
if grep -Fq 'JuicePrepareExecutableRegion' "$ROOT/patches/fex-stikdebug-jit.patch"; then
  echo "StikDebug FEX patch regressed to in-place executable publication." >&2
  exit 3
fi

grep -Fq 'DefaultReserve = 384' "$ROOT/patches/fex-stikdebug-lifecycle.patch"
grep -Fq 'JUICE_STIKDEBUG_JIT_POOL_MB' "$ROOT/patches/fex-stikdebug-lifecycle.patch"
grep -Fq 'JuiceInitializeJITPoolLocked' "$ROOT/patches/fex-stikdebug-lifecycle.patch"
grep -Fq 'Pool.FreeRanges' "$ROOT/patches/fex-stikdebug-lifecycle.patch"
grep -Fq 'after debugger detach' "$ROOT/patches/fex-stikdebug-lifecycle.patch"
grep -Fq 'JuiceDetachJITDebugger' "$ROOT/patches/fex-stikdebug-lifecycle.patch"
grep -Fq 'CurrentCodeBuffer = CodeBuffers.GetLatest()' "$ROOT/patches/fex-stikdebug-lifecycle.patch"

# The base, dual-map, and lifecycle patches are layered intentionally.  The
# fetch/apply scripts must use all layers, and the verifiers must peel them in
# reverse order before comparing the established base deltas.
grep -Fq 'LIFECYCLE_PATCH="$ROOT/patches/fex-stikdebug-lifecycle.patch"' "$ROOT/scripts/fetch-fex-linux.sh"
grep -Fq 'apply --recount "$LIFECYCLE_PATCH"' "$ROOT/scripts/fetch-fex-linux.sh"
grep -Fq 'LIFECYCLE_PATCH="$ROOT/patches/fex-stikdebug-lifecycle.patch"' "$ROOT/scripts/verify-fex-patch.sh"
grep -Fq 'apply --recount --reverse "$LIFECYCLE_PATCH"' "$ROOT/scripts/verify-fex-patch.sh"
grep -Fq 'LIFECYCLE_PATCH="$ROOT/patches/wine-stikdebug-lifecycle.patch"' "$ROOT/scripts/apply-wine-stikdebug-jit.sh"
grep -Fq 'LIFECYCLE_PATCH="$ROOT/patches/wine-stikdebug-lifecycle.patch"' "$ROOT/scripts/verify-wine-patch.sh"

echo "JUICE_STIKDEBUG_JIT_VERIFY_OK lifecycle=1"
