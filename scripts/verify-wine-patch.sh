#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PATCH="$ROOT/patches/wine-ios.patch"
STIKDEBUG_PATCH="$ROOT/patches/wine-stikdebug-jit.patch"
BASE_FILE="$ROOT/config/wine-base.txt"

test -s "$PATCH" || { echo "Missing Wine patch: $PATCH" >&2; exit 2; }
test -s "$STIKDEBUG_PATCH" || { echo "Missing Wine StikDebug JIT patch: $STIKDEBUG_PATCH" >&2; exit 2; }
test -s "$BASE_FILE" || { echo "Missing Wine base revision: $BASE_FILE" >&2; exit 2; }
base="$(tr -d '[:space:]' < "$BASE_FILE")"
case "$base" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
    test "${#base}" -eq 40 || { echo "Invalid Wine base commit: $base" >&2; exit 2; };;
  *) echo "Invalid Wine base commit: $base" >&2; exit 2;;
esac

overlay_applied=0
cleanup()
{
  if test "$overlay_applied" = 1; then
    git -C "$ROOT" apply --directory=wine "$STIKDEBUG_PATCH" || true
  fi
}
trap cleanup EXIT

# The StikDebug JIT changes are deliberately kept as a small overlay on top of
# the established iOS Wine delta.  Accept either a fresh source checkout or an
# incremental build tree where the overlay has already been applied, but always
# verify the underlying wine-ios.patch against the source without that overlay.
if git -C "$ROOT" apply --reverse --check --directory=wine "$STIKDEBUG_PATCH" 2>/dev/null; then
  git -C "$ROOT" apply --reverse --directory=wine "$STIKDEBUG_PATCH"
  overlay_applied=1
else
  git -C "$ROOT" apply --check --directory=wine "$STIKDEBUG_PATCH"
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

if test "$overlay_applied" = 1; then
  git -C "$ROOT" apply --directory=wine "$STIKDEBUG_PATCH"
  overlay_applied=0
  git -C "$ROOT" apply --reverse --check --directory=wine "$STIKDEBUG_PATCH"
fi

stikdebug_paths="$(grep -c '^diff --git a/' "$STIKDEBUG_PATCH")"
test "$stikdebug_paths" -ge 4 || {
  echo "StikDebug Wine patch is unexpectedly short: $stikdebug_paths paths." >&2
  exit 3
}
grep -Fq 'NtWineAllocateJitMemory' "$STIKDEBUG_PATCH"
grep -Fq 'vm_remap' "$STIKDEBUG_PATCH"
grep -Fq 'set_arm64ec_range' "$STIKDEBUG_PATCH"

echo "JUICE_WINE_PATCH_VERIFY_OK base=$base paths=$path_count stikdebug_paths=$stikdebug_paths"
