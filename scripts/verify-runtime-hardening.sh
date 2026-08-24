#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

required=(
  app/JuiceArchitectureRouting.m
  app/JuiceLaunchHardening.m
  app/JuiceRuntimeHardening.m
  app/JuiceWin32Bootstrap.m
  app/JuiceWindowActivation.m
  scripts/run-x86-smoke-device.sh
  scripts/test-zip-extractor-host.sh
)
for path in "${required[@]}"; do
  test -f "$ROOT/$path" || { echo "Missing runtime-hardening source: $path" >&2; exit 2; }
done

# The hardening modules are intentionally separate from the large controller.
# Guard against a build-script cleanup accidentally dropping one of them.
for source in \
  JuiceArchitectureRouting.m JuiceLaunchHardening.m JuiceRuntimeHardening.m \
  JuiceWin32Bootstrap.m JuiceWindowActivation.m; do
  grep -Fq "app/$source" "$ROOT/scripts/build-app.sh" || {
    echo "build-app.sh does not compile $source" >&2
    exit 3
  }
done

# Display transport: dirty rectangles must be understood on both sides, input
# allocations are capped, and UIKit must coalesce producer frames rather than
# enqueueing one multi-megabyte render block per Wine present. Full repaints
# must also reuse an unchanged backing store or they can bypass the coalescer.
grep -Fq 'JUICE_IOS_FRAME_DIRTY' "$ROOT/wine/dlls/wineios.drv/ipc.h"
grep -Fq 'msg.flags=JUICE_IOS_FRAME_DIRTY' "$ROOT/wine/dlls/wineios.drv/ipc.c"
grep -Fq 'JUICE_FRAME_DIRTY' "$ROOT/app/JuiceRuntimeHardening.m"
grep -Fq 'JUICE_MAX_FRAME_BYTES' "$ROOT/app/JuiceRuntimeHardening.m"
grep -Fq 'renderScheduled' "$ROOT/app/JuiceRuntimeHardening.m"
grep -Fq 'frame.generation != generation' "$ROOT/app/JuiceRuntimeHardening.m"
grep -Fq 'existing.width == message.width' "$ROOT/app/JuiceRuntimeHardening.m"
grep -Fq 'memcpy(existing.bytes.mutableBytes, data.bytes, data.length)' "$ROOT/app/JuiceRuntimeHardening.m"

# ZIP extraction must stream deflate output using bounded heap storage. A large
# automatic array here is unsafe on GCD worker stacks and was a prior regression.
grep -Fq 'malloc(JZIOChunkSize)' "$ROOT/app/JuiceZip.m"
if grep -Fq 'uint8_t output[JZIOChunkSize]' "$ROOT/app/JuiceZip.m"; then
  echo "JuiceZip.m regressed to a large stack inflater buffer." >&2
  exit 4
fi
grep -Fq 'Compressed data for %@ ended early.' "$ROOT/app/JuiceZip.m"
grep -Fq 'Checksum verification failed for %@.' "$ROOT/app/JuiceZip.m"

# Spawn lifecycle: do not mutate the UIKit process CWD, isolate the foreground
# process tree when supported, and keep unrelated host descriptors out of Wine.
grep -Fq 'posix_spawn_file_actions_addchdir_np' "$ROOT/app/JuiceLaunchHardening.m"
grep -Fq 'POSIX_SPAWN_SETPGROUP' "$ROOT/app/JuiceLaunchHardening.m"
grep -Fq 'POSIX_SPAWN_CLOEXEC_DEFAULT' "$ROOT/app/JuiceLaunchHardening.m"
grep -Fq 'waitpid(childPID' "$ROOT/app/JuiceLaunchHardening.m"
if grep -Eq '(^|[^A-Za-z_])chdir\(' "$ROOT/app/JuiceLaunchHardening.m"; then
  echo "Launch hardening must not change the host process working directory." >&2
  exit 5
fi

# Experimental Grape-X64 carries both x86-64/ARM64EC and WoW64 FEX translators.
# Keep i386 routing conditional on the packaged runtime and expose HODLL for
# nested 32-bit helpers launched by otherwise 64-bit Windows applications.
grep -Fq 'runtime/lib/wine/i386-windows/ntdll.dll' "$ROOT/app/JuiceArchitectureRouting.m"
grep -Fq 'HODLL=libwow64fex.dll' "$ROOT/app/JuiceArchitectureRouting.m"
grep -Fq 'drive_c/windows/syswow64' "$ROOT/app/JuiceWin32Bootstrap.m"
grep -Fq 'libwow64fex.dll' "$ROOT/app/JuiceWin32Bootstrap.m"
grep -Fq 'JUICE_X86_DEVICE_SMOKE_OK' "$ROOT/scripts/run-x86-smoke-device.sh"
bash -n "$ROOT/scripts/run-x86-smoke-device.sh"

# Multi-window clicks must affect host compositing order as well as Wine focus.
grep -Fq 'wineWindowOrder' "$ROOT/app/JuiceWindowActivation.m"
grep -Fq 'handleCanvasInput:' "$ROOT/app/JuiceWindowActivation.m"
grep -Fq 'compositeWineDesktop' "$ROOT/app/JuiceWindowActivation.m"

echo "JUICE_RUNTIME_HARDENING_VERIFY_OK"
