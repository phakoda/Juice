#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$ROOT/build/sidestore-tests"
mkdir -p "$OUT"
"${CC:-cc}" -std=c11 -O1 -g -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  "$ROOT/tests/test_embedded_policy.c" "$ROOT/runtime/embedded/JuiceEmbeddedPolicy.c" \
  -o "$OUT/embedded-policy"
"$OUT/embedded-policy"
