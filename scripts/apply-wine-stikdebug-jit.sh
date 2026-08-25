#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="${JUICE_WINE_SOURCE:-$ROOT/wine}"
PATCH="$ROOT/patches/wine-stikdebug-jit.patch"

test -d "$SOURCE" || { echo "Missing Wine source tree: $SOURCE" >&2; exit 2; }
test -s "$PATCH" || { echo "Missing Wine StikDebug JIT patch: $PATCH" >&2; exit 2; }

apply_args=()
case "$SOURCE" in
  "$ROOT") ;;
  "$ROOT"/*) apply_args+=(--directory="${SOURCE#$ROOT/}") ;;
  *)
    # The patch is rooted at the Wine source tree.  External build/source
    # checkouts therefore run git-apply from that tree instead of attempting
    # to pass an absolute --directory path to the Juice repository.
    if git -C "$SOURCE" apply --reverse --check "$PATCH" 2>/dev/null; then
      echo "JUICE_WINE_STIKDEBUG_PATCH_REUSE path=$SOURCE"
      exit 0
    fi
    git -C "$SOURCE" apply --check "$PATCH"
    git -C "$SOURCE" apply "$PATCH"
    echo "JUICE_WINE_STIKDEBUG_PATCH_OK path=$SOURCE"
    exit 0
    ;;
esac

if git -C "$ROOT" apply --reverse --check "${apply_args[@]}" "$PATCH" 2>/dev/null; then
  echo "JUICE_WINE_STIKDEBUG_PATCH_REUSE path=$SOURCE"
  exit 0
fi

git -C "$ROOT" apply --check "${apply_args[@]}" "$PATCH"
git -C "$ROOT" apply "${apply_args[@]}" "$PATCH"
echo "JUICE_WINE_STIKDEBUG_PATCH_OK path=$SOURCE"
