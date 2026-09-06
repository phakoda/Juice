#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/juice-fex-codegen.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Extract the actual new production header from the overlay. This lightweight
# test does not pretend to compile FEX; the runtime-build matrix does that.
git -C "$WORK" init -q
git -C "$WORK" apply --include=FEXCore/Source/Interface/Core/JuiceCodegenPolicy.h \
  "$ROOT/patches/fex-juice-codegen.patch"
"${CXX:-clang++}" -std=c++20 -Wall -Wextra -Werror -O1 -g -pthread \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I"$WORK/FEXCore/Source" "$ROOT/tests/test_fex_codegen.cpp" -o "$WORK/test"
"$WORK/test"
