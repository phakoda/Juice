#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/juice-jit-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
"${CC:-clang}" -std=c11 -Wall -Wextra -Werror -O1 -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  "$ROOT/app/tests/JITStateTests.c" -o "$OUT/jit-state"
"$OUT/jit-state"
python3 -m unittest discover -s "$ROOT/launcher/tests" -p 'test_*.py' -v
