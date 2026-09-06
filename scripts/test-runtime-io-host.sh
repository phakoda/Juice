#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/juice-io-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
CC="${CC:-clang}"
flags=(-std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -g -O1)
# Darwin hides BSD socket flags under strict POSIX feature selection.
if [[ "$(uname -s)" = Darwin ]]; then flags+=(-D_DARWIN_C_SOURCE); fi
if [[ "${JUICE_TEST_SANITIZERS:-1}" = 1 ]]; then
  flags+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
fi
"$CC" "${flags[@]}" -pthread "$ROOT/app/JuiceIO.c" "$ROOT/app/tests/IOTests.c" -o "$OUT/io-tests"
"$OUT/io-tests"
if [[ "$(uname -s)" = Darwin ]]; then
  # Compile C separately: -fobjc-arc applies only to Objective-C sources.
  "$CC" "${flags[@]}" -c "$ROOT/app/JuiceIO.c" -o "$OUT/io.o"
  "$CC" "${flags[@]}" -fobjc-arc -fblocks -framework Foundation \
    "$ROOT/app/JuiceAsyncWriter.m" "$ROOT/app/tests/AsyncWriterTests.m" "$OUT/io.o" \
    -o "$OUT/async-writer-tests"
  "$OUT/async-writer-tests"
  "$CC" "${flags[@]}" -fobjc-arc -fblocks -framework Foundation \
    "$ROOT/app/tests/ChildReaperTests.m" -o "$OUT/child-reaper-tests"
  "$OUT/child-reaper-tests"
else
  echo 'JUICE_ASYNC_WRITER_TESTS_SKIP reason=Foundation-requires-macOS'
fi
