#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

required=(
  app/JuiceStikDebugJIT.m
  patches/fex-stikdebug-jit.patch
  patches/wine-stikdebug-jit.patch
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

# Verify the small Wine overlay against either a clean source checkout or a
# source tree that has already been prepared for an incremental build.
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
grep -Fq 'CS_DEBUGGED' "$app"
grep -Fq 'JUICE_STIKDEBUG_JIT=1' "$app"
grep -Fq 'JUICE_STIKDEBUG_TXM=1' "$app"
grep -Fq 'queryItemWithName:@"pid"' "$app"
grep -Fq 'queryItemWithName:@"script-name"' "$app"
grep -Fq '@"universal.js"' "$app"
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

grep -Fq 'WritablePtr' "$ROOT/patches/fex-stikdebug-jit.patch"
grep -Fq 'JuiceAllocateJITMapping' "$ROOT/patches/fex-stikdebug-jit.patch"
grep -Fq 'NtWineAllocateJitMemory' "$ROOT/patches/fex-stikdebug-jit.patch"
grep -Fq 'NtWineFreeJitMemory' "$ROOT/patches/fex-stikdebug-jit.patch"
if grep -Fq 'JuicePrepareExecutableRegion' "$ROOT/patches/fex-stikdebug-jit.patch"; then
  echo "StikDebug FEX patch regressed to in-place executable publication." >&2
  exit 3
fi

# The base and overlay patches are layered intentionally.  The fetch script
# must apply both, and the verifier must know how to temporarily remove only
# the StikDebug overlay before comparing the established base patch.
grep -Fq 'STIKDEBUG_PATCH="$ROOT/patches/fex-stikdebug-jit.patch"' "$ROOT/scripts/fetch-fex-linux.sh"
grep -Fq 'git -C "$SOURCE" apply "$STIKDEBUG_PATCH"' "$ROOT/scripts/fetch-fex-linux.sh"
grep -Fq 'STIKDEBUG_PATCH="$ROOT/patches/fex-stikdebug-jit.patch"' "$ROOT/scripts/verify-fex-patch.sh"
grep -Fq 'apply --reverse "$STIKDEBUG_PATCH"' "$ROOT/scripts/verify-fex-patch.sh"

echo "JUICE_STIKDEBUG_JIT_VERIFY_OK"
