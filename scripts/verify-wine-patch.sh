#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PATCH="$ROOT/patches/wine-ios.patch"
HARDENING_PATCH="$ROOT/patches/wine-ios-runtime-hardening.patch"
BASE_FILE="$ROOT/config/wine-base.txt"

test -s "$PATCH" || { echo "Missing Wine patch: $PATCH" >&2; exit 2; }
test -s "$HARDENING_PATCH" || { echo "Missing Wine runtime hardening patch: $HARDENING_PATCH" >&2; exit 2; }
test -s "$BASE_FILE" || { echo "Missing Wine base revision: $BASE_FILE" >&2; exit 2; }
base="$(tr -d '[:space:]' < "$BASE_FILE")"
case "$base" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
    test "${#base}" -eq 40 || { echo "Invalid Wine base commit: $base" >&2; exit 2; };;
  *) echo "Invalid Wine base commit: $base" >&2; exit 2;;
esac

# wine-ios.patch remains the audited base iOS delta. The mainline-hardening PR
# intentionally changes only three files already introduced by that patch, so
# keep those changes in a small incremental patch rather than rewriting the
# historical 25+ path audit artifact. Verify both layers independently.
#
# git apply's --exclude matching is sensitive to prefix rewriting from
# --directory, so build an explicit filtered base patch instead of depending on
# that interaction. This makes it unambiguous which three paths belong to the
# incremental layer.
filtered="$(mktemp "${TMPDIR:-/tmp}/juice-wine-base-filtered.XXXXXX")"
cleanup(){ rm -f "$filtered"; }
trap cleanup EXIT
awk '
  /^diff --git a\// {
    skip = ($0 ~ /^diff --git a\/dlls\/wineios[.]drv\/(iosdrv[.]c|ipc[.]c|ipc[.]h) b\//)
  }
  !skip { print }
' "$PATCH" > "$filtered"
test -s "$filtered" || { echo "Filtered Wine base patch is empty." >&2; exit 3; }
(
  cd "$ROOT"
  git apply --reverse --check --directory=wine "$filtered"
  git apply --reverse --check --directory=wine "$HARDENING_PATCH"
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

echo "JUICE_WINE_PATCH_VERIFY_OK base=$base paths=$path_count hardening_paths=$hardening_path_count"
