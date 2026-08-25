#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD="$ROOT/scripts/build-app.sh"
IPC_H="$ROOT/wine/dlls/wineios.drv/ipc.h"
IPC_C="$ROOT/wine/dlls/wineios.drv/ipc.c"
IOSDRV="$ROOT/wine/dlls/wineios.drv/iosdrv.c"
DISPLAY="$ROOT/app/JuiceDisplayTransportHardening.m"
SOCKET="$ROOT/app/JuiceSocketHardening.m"
HOSTIO="$ROOT/app/JuiceHostIOHardening.m"
RECONNECT="$ROOT/app/JuiceReconnectGrace.m"
POINTER="$ROOT/app/JuicePointerInput.m"
MEMORY="$ROOT/app/JuiceMemoryPressure.m"
LAUNCH="$ROOT/app/JuiceLaunchHardening.m"
ZIP="$ROOT/app/JuiceZip.m"
ZIP_TEST="$ROOT/scripts/test-zip-extractor-host.sh"

for path in "$BUILD" "$IPC_H" "$IPC_C" "$IOSDRV" "$DISPLAY" "$SOCKET" "$HOSTIO" "$RECONNECT" "$POINTER" "$MEMORY" "$LAUNCH" "$ZIP" "$ZIP_TEST"; do
  test -f "$path" || { echo "Missing mainline hardening source: $path" >&2; exit 2; }
done

# Do not regress the newer verified mainline feature set while porting the old
# reliability work: Vulkan/Metal, client surfaces, GameController and raw HID.
grep -Fq -- '-framework GameController' "$BUILD"
grep -Fq -- '-framework Metal' "$BUILD"
grep -Fq 'pCreateClientSurface=iosdrv_CreateClientSurface' "$IOSDRV"
grep -Fq 'pVulkanInit=iosdrv_VulkanInit' "$IOSDRV"
grep -Fq 'JUICE_IOS_HARDWARE_KEY' "$IPC_H"
grep -Fq 'KEYEVENTF_SCANCODE' "$IPC_C"
grep -Fq 'JUICE_IOS_KEY_EXTENDED' "$IPC_C"

# Software framebuffer transport: track every HWND, seed a complete baseline,
# then transmit packed dirty updates with reconnect generations.
grep -Fq 'surface_list' "$IOSDRV"
grep -Fq 'surface->presented' "$IOSDRV"
grep -Fq 'JUICE_IOS_FRAME_DIRTY' "$IPC_H"
grep -Fq 'ipc_generation' "$IPC_C"
grep -Fq 'connect_ipc_locked' "$IPC_C"
grep -Fq 'writev_all' "$IPC_C"
grep -Fq 'surface_has_baseline_locked' "$IPC_C"

# UIKit must validate/cap payloads and geometry before allocation/compositing,
# then coalesce producer frames before rendering.
grep -Fq 'JUICE_DISPLAY_MAX_BYTES' "$DISPLAY"
grep -Fq 'JUICE_DISPLAY_MAX_DESKTOP_PIXELS' "$DISPLAY"
grep -Fq 'JUICE_DISPLAY_MAX_WINDOW_PIXELS' "$DISPLAY"
grep -Fq 'DISPLAY_GEOMETRY_REJECTED' "$DISPLAY"
grep -Fq 'JUICE_DISPLAY_DIRTY' "$DISPLAY"
grep -Fq 'frame.coalesced++' "$DISPLAY"
grep -Fq 'frame.generation!=generation' "$DISPLAY"
grep -Fq 'presentFrameMessage:data:client:peerPID:first:' "$DISPLAY"

# Host sockets are short, non-inheritable and resilient to transient accept or
# EINTR failures; single-window writes remain serialized through clients.
grep -Fq 'NSTemporaryDirectory()' "$SOCKET"
grep -Fq 'FD_CLOEXEC' "$SOCKET"
grep -Fq 'SO_NOSIGPIPE' "$SOCKET"
grep -Fq 'SOCKET_ACCEPT_RETRY' "$SOCKET"
grep -Fq 'errno==EINTR' "$HOSTIO"
grep -Fq '@synchronized(clients)' "$HOSTIO"

# Short transport interruptions retain window geometry but never keep a closed
# descriptor as an input target. Unrecovered windows are pruned after grace.
grep -Fq 'DISPLAY_RECONNECT_GRACE' "$RECONNECT"
grep -Fq 'DISPLAY_RECONNECT_GRACE_END' "$RECONNECT"
grep -Fq 'inputClient",@(-1)' "$RECONNECT"
grep -Fq 'JuiceReconnectUnchanged' "$RECONNECT"

# iPad pointer hardware should behave like desktop input without stealing finger
# pans: hover, secondary button and vertical/horizontal scroll are transported.
grep -Fq 'UIHoverGestureRecognizer' "$POINTER"
grep -Fq 'UITouchTypeIndirectPointer' "$POINTER"
grep -Fq 'UIEventButtonMaskSecondary' "$POINTER"
grep -Fq 'allowedScrollTypesMask=UIScrollTypeMaskAll' "$POINTER"
grep -Fq 'allowedTouchTypes=@[]' "$POINTER"
grep -Fq 'JUICE_POINTER_WHEEL' "$POINTER"
grep -Fq 'JUICE_POINTER_HWHEEL' "$POINTER"
grep -Fq 'MOUSEEVENTF_WHEEL' "$IPC_C"
grep -Fq 'MOUSEEVENTF_HWHEEL' "$IPC_C"

# Memory warnings may drop redundant hidden UIImage snapshots, but the handler
# must be a JuiceController override instead of replacing UIViewController's IMP.
grep -Fq 'MEMORY_PRESSURE' "$MEMORY"
grep -Fq 'class_addMethod' "$MEMORY"
grep -Fq 'hidden_images_trimmed' "$MEMORY"

# Launches must not split quoted arguments, mutate the UIKit process cwd, or
# silently lose process-group/CLOEXEC semantics. Failures after server startup
# must invoke the existing mainline shutdown path so no wineserver is stranded.
grep -Fq 'JuiceParseArguments' "$LAUNCH"
grep -Fq 'POSIX_SPAWN_CLOEXEC_DEFAULT' "$LAUNCH"
grep -Fq 'posix_spawn_file_actions_addchdir_np' "$LAUNCH"
grep -Fq 'launch-setup-failed' "$LAUNCH"
grep -Fq 'JuiceLaunchStop(self,@"new-launch")' "$LAUNCH"
if grep -Fq 'chdir(' "$LAUNCH"; then
  echo "Launch hardening must use spawn-time cwd, not process-wide chdir()." >&2
  exit 3
fi

# ZIP extraction stays bounded and unambiguous: CP437 legacy names, streaming
# deflate output, local/central cross-checks and partial-file cleanup.
grep -Fq 'kCFStringEncodingDOSLatinUS' "$ZIP"
grep -Fq 'JZIOChunkSize' "$ZIP"
grep -Fq 'JZExtractDeflated' "$ZIP"
grep -Fq 'localCRC != expectedCRC' "$ZIP"
grep -Fq 'duplicate or case-colliding' "$ZIP"
grep -Fq 'unlink(outputPath.fileSystemRepresentation)' "$ZIP"
grep -Fq 'large_size = 48 * 1024 * 1024' "$ZIP_TEST"
grep -Fq 'local-crc-mismatch' "$ZIP_TEST"

for source in JuiceSocketHardening.m JuiceHostIOHardening.m JuiceDisplayTransportHardening.m JuiceReconnectGrace.m JuicePointerInput.m JuiceMemoryPressure.m JuiceLaunchHardening.m; do
  grep -Fq "app/$source" "$BUILD" || { echo "build-app.sh does not compile $source" >&2; exit 3; }
done

echo "JUICE_MAINLINE_HARDENING_VERIFY_OK"
