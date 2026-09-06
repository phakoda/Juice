#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
SOURCE="${JUICE_FEX_SOURCE:-$ROOT/build/fex-source}"
RPMALLOC_SOURCE="$SOURCE/External/rpmalloc"
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$JUICE_FEX_REVISION"
test "$(git -C "$RPMALLOC_SOURCE" rev-parse HEAD)" = "$JUICE_FEX_RPMALLOC_REVISION"
git -C "$SOURCE" diff --check
git -C "$RPMALLOC_SOURCE" diff --check
# Never reverse patches in a live compiler input tree, even temporarily.
python3 "$ROOT/scripts/verify-patch-stack.py" "$SOURCE" \
  "$ROOT/patches/fex-juice-ios.patch" "$ROOT/patches/fex-stikdebug-jit.patch" \
  "$ROOT/patches/fex-stikdebug-lifecycle.patch" "$ROOT/patches/fex-stikdebug-validation.patch" \
  "$ROOT/patches/fex-juice-codegen.patch"
python3 "$ROOT/scripts/verify-patch-stack.py" "$RPMALLOC_SOURCE" "$ROOT/patches/fex-rpmalloc-juice-ios.patch"
echo "JUICE_FEX_PATCH_OK revision=$JUICE_FEX_REVISION rpmalloc_revision=$JUICE_FEX_RPMALLOC_REVISION isolated=1"
