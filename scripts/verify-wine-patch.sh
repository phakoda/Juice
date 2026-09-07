#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PATCH="$ROOT/patches/wine-ios.patch"
HARDENING_PATCH="$ROOT/patches/wine-ios-runtime-hardening.patch"
GRAPHICS_PATCH="$ROOT/patches/wine-ios-graphics.patch"
BASE_FILE="$ROOT/config/wine-base.txt"
IPC_C="$ROOT/wine/dlls/wineios.drv/ipc.c"

test -s "$PATCH" || { echo "Missing Wine patch: $PATCH" >&2; exit 2; }
test -s "$HARDENING_PATCH" || { echo "Missing Wine runtime hardening patch: $HARDENING_PATCH" >&2; exit 2; }
test -s "$GRAPHICS_PATCH" || { echo "Missing Wine graphics patch: $GRAPHICS_PATCH" >&2; exit 2; }
test -s "$BASE_FILE" || { echo "Missing Wine base revision: $BASE_FILE" >&2; exit 2; }
test -s "$IPC_C" || { echo "Missing Wine IPC source: $IPC_C" >&2; exit 2; }
base="$(tr -d '[:space:]' < "$BASE_FILE")"
case "$base" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
    test "${#base}" -eq 40 || { echo "Invalid Wine base commit: $base" >&2; exit 2; };;
  *) echo "Invalid Wine base commit: $base" >&2; exit 2;;
esac

# Peel the overlay and then the COMPLETE base patch in an isolated copy. Never
# mutate live build inputs or exclude files changed by an incremental layer.
python3 "$ROOT/scripts/verify-patch-stack.py" "$ROOT/wine" "$PATCH" "$HARDENING_PATCH" "$GRAPHICS_PATCH" --optional \
  "$ROOT/patches/wine-stikdebug-jit.patch" "$ROOT/patches/wine-stikdebug-lifecycle.patch" \
  "$ROOT/patches/wine-stikdebug-handoff.patch" "$ROOT/patches/wine-stikdebug-abi.patch" \
  "$ROOT/patches/wine-ios-embedded.patch"

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

hardening_path_count="$(grep -c '^diff --git a/' "$HARDENING_PATCH")"
test "$hardening_path_count" -eq 3 || {
  echo "Wine runtime hardening patch must contain exactly 3 paths; found $hardening_path_count." >&2
  exit 3
}
for path in iosdrv.c ipc.c ipc.h; do
  grep -Fq "diff --git a/dlls/wineios.drv/$path b/dlls/wineios.drv/$path" "$HARDENING_PATCH" || {
    echo "Wine runtime hardening patch is missing dlls/wineios.drv/$path" >&2
    exit 3
  }
done
if grep '^diff --git a/' "$HARDENING_PATCH" | grep -Ev '^diff --git a/dlls/wineios\.drv/(iosdrv\.c|ipc\.c|ipc\.h) b/' >/dev/null; then
  echo "Wine runtime hardening patch unexpectedly touches another Wine path." >&2
  exit 3
fi

# Reconnect/input invariants: a drag capture belongs only to the IPC generation
# that created it, and retained child keyboard/text focus may be reused only
# when that child still belongs to the selected top-level HWND's root.
grep -Fq 'pointer_down&&input_target&&pointer_generation==generation&&!down' "$IPC_C"
grep -Fq 'pointer_generation=generation;' "$IPC_C"
grep -Fq 'static HWND selected_input_target(HWND hwnd)' "$IPC_C"
grep -Fq 'NtUserGetAncestor(input_target,GA_ROOT)' "$IPC_C"
test "$(grep -Fc 'target=selected_input_target(hwnd);' "$IPC_C")" -eq 3 || {
  echo "Wine text/virtual-key/hardware-key routing must validate retained child focus against the selected HWND." >&2
  exit 3
}
grep -Fq 'pointer_generation=generation;' "$HARDENING_PATCH"
grep -Fq 'selected_input_target(HWND hwnd)' "$HARDENING_PATCH"

echo "JUICE_WINE_PATCH_VERIFY_OK base=$base paths=$path_count hardening_paths=$hardening_path_count"
