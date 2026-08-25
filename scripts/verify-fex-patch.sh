#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
SOURCE="${JUICE_FEX_SOURCE:-$ROOT/build/fex-source}"
PATCH="$ROOT/patches/fex-juice-ios.patch"
STIKDEBUG_PATCH="$ROOT/patches/fex-stikdebug-jit.patch"
RPMALLOC_SOURCE="$SOURCE/External/rpmalloc"
RPMALLOC_PATCH="$ROOT/patches/fex-rpmalloc-juice-ios.patch"

test -d "$SOURCE/.git" || { echo "Run scripts/fetch-fex-linux.sh first." >&2; exit 2; }
test -s "$STIKDEBUG_PATCH" || { echo "Missing FEX StikDebug JIT patch." >&2; exit 2; }
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$JUICE_FEX_REVISION" || {
  echo "FEX source is not at the pinned revision." >&2
  exit 2
}
git -C "$SOURCE" diff --check
test "$(git -C "$RPMALLOC_SOURCE" rev-parse HEAD)" = "$JUICE_FEX_RPMALLOC_REVISION" || {
  echo "FEX rpmalloc submodule is not at the pinned revision." >&2
  exit 2
}
git -C "$RPMALLOC_SOURCE" diff --check

# The StikDebug patch is intentionally layered on top of fex-juice-ios.patch
# and touches some of the same files.  Verify that the combined checkout can
# reverse the overlay, then compare the remaining tree byte-for-byte with the
# base patch.  Re-apply the overlay before returning so verification is
# non-destructive for incremental builds.  --recount lets the hand-edited
# overlay derive hunk sizes from its actual lines while still checking context.
git -C "$SOURCE" apply --recount --reverse --check "$STIKDEBUG_PATCH"
git -C "$RPMALLOC_SOURCE" apply --reverse --check "$RPMALLOC_PATCH"
temporary="$(mktemp "$ROOT/build/fex-patch-verify.XXXXXX")"
rpmalloc_temporary="$(mktemp "$ROOT/build/fex-rpmalloc-patch-verify.XXXXXX")"
stikdebug_reversed=0
cleanup()
{
  if test "$stikdebug_reversed" = 1; then
    git -C "$SOURCE" apply --recount "$STIKDEBUG_PATCH" || true
  fi
  case "$temporary" in "$ROOT"/build/fex-patch-verify.*) rm -f "$temporary";; esac
  case "$rpmalloc_temporary" in "$ROOT"/build/fex-rpmalloc-patch-verify.*) rm -f "$rpmalloc_temporary";; esac
}
trap cleanup EXIT

git -C "$SOURCE" apply --recount --reverse "$STIKDEBUG_PATCH"
stikdebug_reversed=1
git -C "$SOURCE" apply --recount --check "$STIKDEBUG_PATCH"
git -C "$SOURCE" apply --reverse --check "$PATCH"

git -C "$SOURCE" diff --no-ext-diff --src-prefix=a/ --dst-prefix=b/ \
  --output="$temporary" -- . ':(exclude)External/rpmalloc'
git -C "$RPMALLOC_SOURCE" diff --no-ext-diff --src-prefix=a/ --dst-prefix=b/ \
  --output="$rpmalloc_temporary"
cmp -s "$temporary" "$PATCH" || {
  echo "patches/fex-juice-ios.patch is stale." >&2
  exit 3
}
cmp -s "$rpmalloc_temporary" "$RPMALLOC_PATCH" || {
  echo "patches/fex-rpmalloc-juice-ios.patch is stale." >&2
  exit 3
}

git -C "$SOURCE" apply --recount "$STIKDEBUG_PATCH"
stikdebug_reversed=0
git -C "$SOURCE" diff --check

echo "JUICE_FEX_PATCH_OK revision=$JUICE_FEX_REVISION rpmalloc_revision=$JUICE_FEX_RPMALLOC_REVISION stikdebug_jit=1"
