#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/juice-transport.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CC="${CC:-clang}"
extra=()
if test "$(uname -s)" = Darwin; then extra+=(-D_DARWIN_C_SOURCE); fi
"$CC" "${extra[@]}" -std=c11 -O1 -g -Wall -Wextra -Werror -pthread \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  "$ROOT/app/tests/SocketIOTests.c" -o "$WORK/socket-io"
"$WORK/socket-io"
if test "$(uname -s)" = Darwin; then
  "$CC" -std=c11 -O1 -g -fsanitize=address,undefined -c "$ROOT/app/JuicePresentationPolicy.c" -o "$WORK/policy.o"
  "$CC" -std=c11 -O1 -g -fsanitize=address,undefined -c "$ROOT/app/JuiceKeyChord.c" -o "$WORK/chord.o"
  "$CC" -O1 -g -fsanitize=address,undefined -c "$ROOT/app/JuiceIO.c" -o "$WORK/io.o"
  "$CC" -fobjc-arc -fblocks -O1 -g -Wall -Wextra \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$ROOT/app/tests/LogRetentionTests.m" -framework Foundation -o "$WORK/log-retention"
  "$WORK/log-retention"
  "$CC" -fobjc-arc -fblocks -O1 -g -Wall -Wextra \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$ROOT/app/tests/DisplayTransportTests.m" "$ROOT/app/JuiceHostIOHardening.m" \
    "$ROOT/app/JuiceAsyncWriter.m" "$WORK/io.o" "$WORK/policy.o" "$WORK/chord.o" -framework Foundation -framework CoreGraphics \
    -o "$WORK/display-transport"
  "$WORK/display-transport"
fi
