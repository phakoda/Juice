#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CC="${CC:-clang}"
"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
  "$ROOT/app/JuicePresentationPolicy.c" "$ROOT/app/tests/PresentationPolicyTests.c" \
  -lm -o "$WORK/presentation-policy"
"$WORK/presentation-policy"
"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
  "$ROOT/app/JuiceKeyChord.c" "$ROOT/app/tests/KeyChordTests.c" -o "$WORK/key-chord"
"$WORK/key-chord"
if test "$(uname -s)" = Darwin; then
  "$CC" -std=c11 -O1 -g -fsanitize=address,undefined -c \
    "$ROOT/app/JuicePresentationPolicy.c" -o "$WORK/policy.o"
  "$CC" -fobjc-arc -fblocks -O1 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined "$ROOT/app/JuiceMetalCore.m" \
    "$ROOT/app/tests/MetalCoreTests.m" "$WORK/policy.o" \
    -framework Foundation -framework Metal -o "$WORK/metal-core"
  "$WORK/metal-core"
  "$CC" -std=c11 -O1 -g -fsanitize=address,undefined -c "$ROOT/app/JuiceKeyChord.c" -o "$WORK/chord.o"
  "$CC" -O1 -g -fsanitize=address,undefined -c "$ROOT/app/JuiceIO.c" -o "$WORK/io.o"
  "$CC" -fobjc-arc -fblocks -O1 -g -Wall -Wextra -fsanitize=address,undefined \
    "$ROOT/app/tests/InputBatchTests.m" "$ROOT/app/JuiceHostIOHardening.m" \
    "$ROOT/app/JuiceAsyncWriter.m" "$WORK/chord.o" "$WORK/io.o" \
    -framework Foundation -o "$WORK/input-batch"
  "$WORK/input-batch"
else
  echo 'METAL_CORE_TESTS_SKIP reason=non-apple-host gpu-pixels-not-validated'
fi
