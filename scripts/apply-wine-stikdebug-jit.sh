#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="${JUICE_WINE_SOURCE:-$ROOT/wine}"
PATCH="$ROOT/patches/wine-stikdebug-jit.patch"
LIFECYCLE_PATCH="$ROOT/patches/wine-stikdebug-lifecycle.patch"
HANDOFF_PATCH="$ROOT/patches/wine-stikdebug-handoff.patch"
# Validate every base and optional layer in isolation before mutating any build
# input. Incremental trees are accepted only as a complete ordered prefix.
applied="$(python3 "$ROOT/scripts/verify-patch-stack.py" "$SOURCE" \
  "$ROOT/patches/wine-ios.patch" "$ROOT/patches/wine-ios-runtime-hardening.patch" \
  "$ROOT/patches/wine-ios-graphics.patch" \
  --optional "$PATCH" "$LIFECYCLE_PATCH" "$HANDOFF_PATCH" --applied-count)"
patches=("$PATCH" "$LIFECYCLE_PATCH" "$HANDOFF_PATCH")
apply_root="$SOURCE"
apply_args=()
case "$SOURCE" in
  "$ROOT"/*) apply_root="$ROOT"; apply_args+=(--directory="${SOURCE#$ROOT/}");;
esac
for ((index=applied;index<${#patches[@]};index++)); do
  git -C "$apply_root" apply --recount --check "${apply_args[@]}" "${patches[$index]}"
  git -C "$apply_root" apply --recount "${apply_args[@]}" "${patches[$index]}"
done
echo "JUICE_WINE_STIKDEBUG_PATCH_OK path=$SOURCE previous_layers=$applied lifecycle=1 handoff=1"
