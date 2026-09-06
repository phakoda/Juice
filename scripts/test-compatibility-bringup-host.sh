#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CC="${CC:-clang}"
flags=(-std=c11 -O1 -g -Wall -Wextra -Werror -fno-omit-frame-pointer)
if [[ "${JUICE_SANITIZERS:-1}" == 1 ]]; then flags+=(-fsanitize=address,undefined); fi
run() {
  local name="$1"; shift
  "$CC" "${flags[@]}" -I"$ROOT/app" "$ROOT/tests/host/test_${name}.c" "$@" -o "$TMP/$name"
  "$TMP/$name"
}
run utf8_stream "$ROOT/app/JuiceUTF8Stream.c"
run pe_inspect "$ROOT/app/JuicePEInspect.c"
run profile_policy "$ROOT/app/JuiceProfilePolicy.c"
python3 -S -m unittest discover -s "$ROOT/tests/host" -p 'test_runtime_evidence.py' -v
echo JUICE_COMPATIBILITY_BRINGUP_HOST_TESTS_OK
