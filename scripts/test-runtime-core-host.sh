#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/juice-runtime-core.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CC="${CC:-clang}"
CXX="${CXX:-clang++}"
fixture=()
case "${JUICE_RUNTIME_CORE_FIXTURE:-0}" in
  0) ;;
  1) fixture=(--fixture) ;;
  *) echo 'JUICE_RUNTIME_CORE_FIXTURE must be 0 or 1.' >&2; exit 2 ;;
esac
python3 "$ROOT/scripts/prepare-runtime-core-tests.py" --root "$ROOT" --output "$WORK" "${fixture[@]}"
python3 "$ROOT/scripts/juice_graphics_manifest.py" --root "$ROOT" "${fixture[@]}"
python3 -m unittest discover -s "$ROOT/scripts/tests" -p test_runtime_core.py -v
flags=(-O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer)
"$CC" --version | head -n 1
"$CXX" --version | head -n 1
"$CC" -std=c11 "${flags[@]}" "$ROOT/app/tests/JITStateTests.c" -o "$WORK/jit-state"
"$CC" -std=c11 "${flags[@]}" "$ROOT/app/tests/JITAckTests.c" -o "$WORK/jit-ack"
"$CC" -std=c11 "${flags[@]}" -I"$ROOT/wine/dlls/wineios.drv" "$ROOT/tests/runtime-bringup/GraphicsLayoutTests.c" -o "$WORK/graphics"
"$CC" -std=c11 "${flags[@]}" -I"$WORK" "$ROOT/tests/runtime-bringup/PresentationQueryTests.c" -o "$WORK/query"
"$CXX" -std=c++20 "${flags[@]}" -pthread -I"$WORK" "$ROOT/tests/runtime-bringup/FEXPolicyTests.cpp" -o "$WORK/fex-policy"
"$CXX" -std=c++20 "${flags[@]}" -I"$WORK" "$ROOT/tests/runtime-bringup/FEXPlacementIntegrationTests.cpp" -o "$WORK/fex-placement"
for test in jit-state jit-ack graphics query fex-policy fex-placement; do
  "$WORK/$test"
done
printf 'JUICE_RUNTIME_CORE_HOST_TESTS_OK fixture=%s apple_runtime_built=0 fex_runtime_built=0\n' "${JUICE_RUNTIME_CORE_FIXTURE:-0}"
