#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/juice-graphics-policy.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
"${CC:-clang}" -std=c11 -Wall -Wextra -Werror -O2 -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  "$ROOT/tests/test_graphics_policy.c" -o "$WORK/test"
"$WORK/test"
