#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="${JUICE_WINE_SOURCE:-$ROOT/wine}"
PATCH="$ROOT/patches/wine-stikdebug-jit.patch"
LIFECYCLE_PATCH="$ROOT/patches/wine-stikdebug-lifecycle.patch"

test -d "$SOURCE" || { echo "Missing Wine source tree: $SOURCE" >&2; exit 2; }
test -s "$PATCH" || { echo "Missing Wine StikDebug JIT patch: $PATCH" >&2; exit 2; }
test -s "$LIFECYCLE_PATCH" || { echo "Missing Wine StikDebug lifecycle patch: $LIFECYCLE_PATCH" >&2; exit 2; }

apply_args=()
case "$SOURCE" in
  "$ROOT") ;;
  "$ROOT"/*) apply_args+=(--directory="${SOURCE#$ROOT/}") ;;
  *)
    # A fully prepared tree has the lifecycle layer on top.  Check it first,
    # because it intentionally edits lines introduced by the StikDebug patch.
    if git -C "$SOURCE" apply --recount --reverse --check "$LIFECYCLE_PATCH" 2>/dev/null; then
      echo "JUICE_WINE_STIKDEBUG_PATCH_REUSE path=$SOURCE lifecycle=1"
      exit 0
    fi
    if ! git -C "$SOURCE" apply --recount --reverse --check "$PATCH" 2>/dev/null; then
      git -C "$SOURCE" apply --recount --check "$PATCH"
      git -C "$SOURCE" apply --recount "$PATCH"
    fi
    git -C "$SOURCE" apply --recount --check "$LIFECYCLE_PATCH"
    git -C "$SOURCE" apply --recount "$LIFECYCLE_PATCH"
    echo "JUICE_WINE_STIKDEBUG_PATCH_OK path=$SOURCE lifecycle=1"
    exit 0
    ;;
esac

if git -C "$ROOT" apply --recount --reverse --check "${apply_args[@]}" "$LIFECYCLE_PATCH" 2>/dev/null; then
  echo "JUICE_WINE_STIKDEBUG_PATCH_REUSE path=$SOURCE lifecycle=1"
  exit 0
fi

if ! git -C "$ROOT" apply --recount --reverse --check "${apply_args[@]}" "$PATCH" 2>/dev/null; then
  git -C "$ROOT" apply --recount --check "${apply_args[@]}" "$PATCH"
  git -C "$ROOT" apply --recount "${apply_args[@]}" "$PATCH"
fi
git -C "$ROOT" apply --recount --check "${apply_args[@]}" "$LIFECYCLE_PATCH"
git -C "$ROOT" apply --recount "${apply_args[@]}" "$LIFECYCLE_PATCH"
echo "JUICE_WINE_STIKDEBUG_PATCH_OK path=$SOURCE lifecycle=1"
