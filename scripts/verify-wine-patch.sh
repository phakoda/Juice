#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PATCH="$ROOT/patches/wine-ios.patch"
STIKDEBUG_PATCH="$ROOT/patches/wine-stikdebug-jit.patch"
LIFECYCLE_PATCH="$ROOT/patches/wine-stikdebug-lifecycle.patch"
BASE_FILE="$ROOT/config/wine-base.txt"

test -s "$PATCH" || { echo "Missing Wine patch: $PATCH" >&2; exit 2; }
test -s "$STIKDEBUG_PATCH" || { echo "Missing Wine StikDebug JIT patch: $STIKDEBUG_PATCH" >&2; exit 2; }
test -s "$LIFECYCLE_PATCH" || { echo "Missing Wine StikDebug lifecycle patch: $LIFECYCLE_PATCH" >&2; exit 2; }
test -s "$BASE_FILE" || { echo "Missing Wine base revision: $BASE_FILE" >&2; exit 2; }
base="$(tr -d '[:space:]' < "$BASE_FILE")"
case "$base" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
    test "${#base}" -eq 40 || { echo "Invalid Wine base commit: $base" >&2; exit 2; };;
  *) echo "Invalid Wine base commit: $base" >&2; exit 2;;
esac

lifecycle_reversed=0
stikdebug_reversed=0
temporary_stikdebug=0
cleanup()
{
  if test "$temporary_stikdebug" = 1; then
    git -C "$ROOT" apply --recount --reverse --directory=wine "$STIKDEBUG_PATCH" || true
    temporary_stikdebug=0
  fi
  if test "$stikdebug_reversed" = 1; then
    git -C "$ROOT" apply --recount --directory=wine "$STIKDEBUG_PATCH" || true
    stikdebug_reversed=0
  fi
  if test "$lifecycle_reversed" = 1; then
    git -C "$ROOT" apply --recount --directory=wine "$LIFECYCLE_PATCH" || true
    lifecycle_reversed=0
  fi
}
trap cleanup EXIT

# Preserve the source tree's original state while peeling the lifecycle layer
# and then the dual-map overlay off the established iOS Wine delta.
if git -C "$ROOT" apply --recount --reverse --check --directory=wine "$LIFECYCLE_PATCH" 2>/dev/null; then
  git -C "$ROOT" apply --recount --reverse --directory=wine "$LIFECYCLE_PATCH"
  lifecycle_reversed=1
fi
if git -C "$ROOT" apply --recount --reverse --check --directory=wine "$STIKDEBUG_PATCH" 2>/dev/null; then
  git -C "$ROOT" apply --recount --reverse --directory=wine "$STIKDEBUG_PATCH"
  stikdebug_reversed=1
else
  git -C "$ROOT" apply --recount --check --directory=wine "$STIKDEBUG_PATCH"
fi

(
  cd "$ROOT"
  git apply --reverse --check --directory=wine patches/wine-ios.patch
)

path_count="$(grep -c '^diff --git a/' "$PATCH")"
test "$path_count" -ge 25 || {
  echo "Wine patch contains only $path_count paths; expected the complete iOS delta." >&2
  exit 3
}
grep -Fq ' b/UPSTREAM-JUICE.txt' "$PATCH" || {
  echo "Wine patch is missing UPSTREAM-JUICE.txt" >&2
  exit 3
}
for path in Makefile.in dllmain.c iosdrv.c iosdrv.h ipc.c ipc.h; do
  grep -Fq " b/dlls/wineios.drv/$path" "$PATCH" || {
    echo "Wine patch is missing dlls/wineios.drv/$path" >&2
    exit 3
  }
done

# Validate both overlay layers in order.  Re-applying the first layer here is
# temporary only when the caller supplied a fresh base tree.
git -C "$ROOT" apply --recount --check --directory=wine "$STIKDEBUG_PATCH"
git -C "$ROOT" apply --recount --directory=wine "$STIKDEBUG_PATCH"
if test "$stikdebug_reversed" = 1; then
  stikdebug_reversed=0
else
  temporary_stikdebug=1
fi
git -C "$ROOT" apply --recount --check --directory=wine "$LIFECYCLE_PATCH"
if test "$lifecycle_reversed" = 1; then
  git -C "$ROOT" apply --recount --directory=wine "$LIFECYCLE_PATCH"
  lifecycle_reversed=0
fi
if test "$temporary_stikdebug" = 1; then
  git -C "$ROOT" apply --recount --reverse --directory=wine "$STIKDEBUG_PATCH"
  temporary_stikdebug=0
fi

stikdebug_paths="$(grep -c '^diff --git a/' "$STIKDEBUG_PATCH")"
test "$stikdebug_paths" -ge 4 || {
  echo "StikDebug Wine patch is unexpectedly short: $stikdebug_paths paths." >&2
  exit 3
}
grep -Fq 'NtWineAllocateJitMemory' "$STIKDEBUG_PATCH"
grep -Fq 'vm_remap' "$STIKDEBUG_PATCH"
grep -Fq 'set_arm64ec_range' "$STIKDEBUG_PATCH"

lifecycle_paths="$(grep -c '^diff --git a/' "$LIFECYCLE_PATCH")"
test "$lifecycle_paths" -eq 1 || {
  echo "StikDebug lifecycle Wine patch should only touch virtual.c; got $lifecycle_paths paths." >&2
  exit 3
}
grep -Fq 'brk #0x3caf' "$LIFECYCLE_PATCH"
grep -Fq 'juice_jit_allocation_sealed' "$LIFECYCLE_PATCH"
grep -Fq 'STATUS_ACCESS_DENIED' "$LIFECYCLE_PATCH"

echo "JUICE_WINE_PATCH_VERIFY_OK base=$base paths=$path_count stikdebug_paths=$stikdebug_paths lifecycle_paths=$lifecycle_paths"
