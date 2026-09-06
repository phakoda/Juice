#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
for path in app/JuiceStikDebugJIT.h app/JuiceStikDebugJIT.m app/JuiceJITState.h \
  scripts/apply-wine-stikdebug-jit.sh scripts/fetch-fex-linux.sh scripts/verify-fex-patch.sh; do
  test -s "$ROOT/$path" || { echo "Missing JIT integration: $path" >&2; exit 2; }
done
bash -n "$ROOT/scripts/apply-wine-stikdebug-jit.sh" "$ROOT/scripts/fetch-fex-linux.sh" "$ROOT/scripts/verify-fex-patch.sh"
for patch in fex-stikdebug-jit fex-stikdebug-lifecycle fex-stikdebug-validation wine-stikdebug-jit wine-stikdebug-lifecycle wine-stikdebug-handoff wine-stikdebug-abi; do
  git -C "$ROOT" apply --recount --numstat "$ROOT/patches/$patch.patch" >/dev/null
done
# Actual reverse/replay validation, not a grep-only claim of patch integrity.
bash "$ROOT/scripts/verify-wine-patch.sh"
python3 - "$ROOT/config/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as file:
    schemes=set(plistlib.load(file).get('LSApplicationQueriesSchemes',[]))
assert {'stikdebug','stikjit'} <= schemes
print('JUICE_STIKDEBUG_INFO_PLIST_OK')
PY
app="$ROOT/app/JuiceStikDebugJIT.m"
grep -Fq 'JuiceSpawnForLaunch(self,' "$ROOT/app/JuiceLaunchHardening.m"
grep -Fq 'JuiceJITWillReap(self,child,generation)' "$ROOT/app/JuiceLaunchHardening.m"
grep -Fq 'JuiceJITOwnsChild' "$app"
grep -Fq 'JUICE_ENABLE_STIKDEBUG_JIT=1' "$app"
grep -Fq 'get-task-allow' "$app"
grep -Fq 'JuiceStikDebugJIT.m' "$ROOT/scripts/build-app.sh"
grep -Fq 'JUICE_JIT_RUNTIME_READY' "$ROOT/patches/wine-stikdebug-handoff.patch"
grep -Fq 'execve(argv[1], &argv[1], environ)' "$ROOT/launcher/grape-trace-parent.c"
grep -Fq 'verify-patch-stack.py' "$ROOT/scripts/verify-fex-patch.sh"
grep -Fq 'AllocatedRanges' "$ROOT/patches/fex-stikdebug-validation.patch"
if grep -Eq '^int posix_spawn\(' "$app"; then
  echo 'Process-wide spawn interposition must not return.' >&2; exit 3
fi
echo 'JUICE_STIKDEBUG_JIT_VERIFY_OK lifecycle=1 handoff=1 allocation_validation=1 pointer_sized_abi=1'
