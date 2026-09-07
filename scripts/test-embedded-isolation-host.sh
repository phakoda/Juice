#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test "$(uname -s)" = Darwin || { echo 'Darwin per-thread cwd/signal isolation test requires macOS.' >&2; exit 2; }
OUT="$ROOT/build/sidestore-tests"
mkdir -p "$OUT"
"${CC:-cc}" -std=gnu11 -O1 -g -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  "$ROOT/tests/test_embedded_isolation.c" \
  "$ROOT/runtime/embedded/JuiceEmbeddedPolicy.c" "$ROOT/runtime/embedded/JuiceEmbeddedMemory.c" \
  -o "$OUT/embedded-isolation"
"$OUT/embedded-isolation"
