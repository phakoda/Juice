#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="${JUICE_WINE_SOURCE:-$ROOT/wine}"
bash "$ROOT/scripts/apply-wine-stikdebug-jit.sh"
applied="$(python3 "$ROOT/scripts/verify-patch-stack.py" "$SOURCE" \
  "$ROOT/patches/wine-ios.patch" "$ROOT/patches/wine-ios-runtime-hardening.patch" \
  "$ROOT/patches/wine-ios-graphics.patch" --optional \
  "$ROOT/patches/wine-stikdebug-jit.patch" "$ROOT/patches/wine-stikdebug-lifecycle.patch" \
  "$ROOT/patches/wine-stikdebug-handoff.patch" "$ROOT/patches/wine-stikdebug-abi.patch" \
  "$ROOT/patches/wine-ios-embedded.patch" --applied-count)"
if test "$applied" = 4; then
  apply_root="$SOURCE"; args=()
  case "$SOURCE" in "$ROOT"/*) apply_root="$ROOT"; args+=(--directory="${SOURCE#$ROOT/}");; esac
  git -C "$apply_root" apply --check "${args[@]}" "$ROOT/patches/wine-ios-embedded.patch"
  git -C "$apply_root" apply "${args[@]}" "$ROOT/patches/wine-ios-embedded.patch"
elif test "$applied" != 5; then
  echo "Incomplete JIT/embedded patch stack: $applied" >&2; exit 3
fi
# Native configure/makedep resolves these quoted headers in its include tree.
# They are source inputs, not generated binaries and never go in the IPA.
mkdir -p "$SOURCE/include/juice"
cp "$ROOT/runtime/embedded/JuiceEmbeddedRuntime.h" "$SOURCE/include/juice/"
cp "$ROOT/runtime/embedded/JuiceEmbeddedShim.h" "$SOURCE/include/juice/"
echo "JUICE_EMBEDDED_WINE_PATCH_OK layers=5 source=$SOURCE"
