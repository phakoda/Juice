#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD="$ROOT/scripts/build-app.sh"
IPC_H="$ROOT/wine/dlls/wineios.drv/ipc.h"
IPC_C="$ROOT/wine/dlls/wineios.drv/ipc.c"
IOSDRV="$ROOT/wine/dlls/wineios.drv/iosdrv.c"
MULTI="$ROOT/app/JuiceMultiWindowFix.m"
DISPLAY="$ROOT/app/JuiceDisplayTransportHardening.m"
SOCKET="$ROOT/app/JuiceSocketHardening.m"
HOSTIO="$ROOT/app/JuiceHostIOHardening.m"
RECONNECT="$ROOT/app/JuiceReconnectGrace.m"
DATA_IMPORT="$ROOT/app/JuiceWindowsDataImport.m"
POINTER="$ROOT/app/JuicePointerInput.m"
MEMORY="$ROOT/app/JuiceMemoryPressure.m"
LIFECYCLE="$ROOT/app/JuiceLifecycleHardening.m"
CLI_INPUT="$ROOT/app/JuiceCLIInputHardening.m"
LAUNCH="$ROOT/app/JuiceLaunchHardening.m"
TRACE_PARENT="$ROOT/launcher/grape-trace-parent.c"
ZIP="$ROOT/app/JuiceZip.m"
ZIP_TEST="$ROOT/scripts/test-zip-extractor-host.sh"

for path in "$BUILD" "$IPC_H" "$IPC_C" "$IOSDRV" "$MULTI" "$DISPLAY" "$SOCKET" "$HOSTIO" "$RECONNECT" "$DATA_IMPORT" "$POINTER" "$MEMORY" "$LIFECYCLE" "$CLI_INPUT" "$LAUNCH" "$TRACE_PARENT" "$ZIP" "$ZIP_TEST"; do
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
# then transmit packed dirty updates with reconnect generations. Disconnects
# from stale readers must match both fd and connection generation.
grep -Fq 'surface_list' "$IOSDRV"
grep -Fq 'surface->presented' "$IOSDRV"
grep -Fq 'JUICE_IOS_FRAME_DIRTY' "$IPC_H"
grep -Fq 'ipc_generation' "$IPC_C"
grep -Fq 'connect_ipc_locked' "$IPC_C"
grep -Fq 'writev_all' "$IPC_C"
grep -Fq 'surface_has_baseline_locked' "$IPC_C"
grep -Fq 'disconnect_ipc_connection' "$IPC_C"
grep -Fq 'ipc_fd==fd&&ipc_generation==generation' "$IPC_C"

# Preserve current main's viewport and desktop-coordinate drag fixes while
# collapsing multiple HWND redraws into one pending full-viewport composite.
grep -Fq 'INPUT_COORDS_DESKTOP' "$MULTI"
grep -Fq 'JuiceCapturedViewportKey' "$MULTI"
grep -Fq 'JuiceRenderCompositeWineDesktop' "$MULTI"
grep -Fq 'JuiceCompositeScheduledKey' "$MULTI"
grep -Fq 'MULTI_WINDOW_COMPOSITE_COALESCED' "$MULTI"
grep -Fq 'dispatch_get_main_queue()' "$MULTI"

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

# Host sockets are short/non-inheritable and survive sustained transient accept
# pressure. Per-listener generations plus SO_ACCEPTCONN/path verification prevent
# old loops or lifecycle recovery from trusting/closing a reused unrelated fd.
grep -Fq 'NSTemporaryDirectory()' "$SOCKET"
grep -Fq 'FD_CLOEXEC' "$SOCKET"
grep -Fq 'SO_NOSIGPIPE' "$SOCKET"
grep -Fq 'SO_ACCEPTCONN' "$SOCKET"
grep -Fq 'JuiceListenerFDMatchesPath' "$SOCKET"
grep -Fq 'JuiceListenerGeneration' "$SOCKET"
grep -Fq 'persistent=1' "$SOCKET"
grep -Fq 'SOCKET_BIND_RETRY' "$SOCKET"
if grep -Fq 'failures++<20' "$SOCKET"; then
  echo "Socket accept recovery must not permanently stop after a fixed retry count." >&2
  exit 3
fi
grep -Fq 'errno==EINTR' "$HOSTIO"
grep -Fq '@synchronized(clients)' "$HOSTIO"

# Short transport interruptions retain window geometry but never keep a closed
# descriptor as an input target. Unrecovered windows are pruned after grace.
grep -Fq 'DISPLAY_RECONNECT_GRACE' "$RECONNECT"
grep -Fq 'DISPLAY_RECONNECT_GRACE_END' "$RECONNECT"
grep -Fq 'inputClient",@(-1)' "$RECONNECT"
grep -Fq 'JuiceReconnectUnchanged' "$RECONNECT"

# Imported MSI/BAT/CMD/REG files launch through current main's helper/runtime
# flags, not the obsolete force-translation hook from the old branch.
grep -Fq 'msiexec.exe' "$DATA_IMPORT"
grep -Fq 'cmd.exe' "$DATA_IMPORT"
grep -Fq 'reg.exe' "$DATA_IMPORT"
grep -Fq 'usingX64",@YES' "$DATA_IMPORT"
grep -Fq 'usingWin32",@YES' "$DATA_IMPORT"
grep -Fq 'translatedRuntimeIsSafe:detail:' "$DATA_IMPORT"
grep -Fq 'libarm64ecfex.dll' "$DATA_IMPORT"
grep -Fq 'libwow64fex.dll' "$DATA_IMPORT"
if grep -Fq 'juice_forceTranslatedRuntimeForNextLaunch' "$DATA_IMPORT"; then
  echo "Windows data import must use current main runtime flags, not the old force hook." >&2
  exit 3
fi

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

# Foregrounding repairs missing listeners, backgrounding drops stale pointer
# capture, and newer mainline host FDs are explicitly close-on-exec. Lifecycle
# ownership checks must not close an unrelated fd that reused a listener number.
grep -Fq 'UIApplicationWillEnterForegroundNotification' "$LIFECYCLE"
grep -Fq 'listener_restart=' "$LIFECYCLE"
grep -Fq 'gamepadFD' "$LIFECYCLE"
grep -Fq 'persistentLogHandle' "$LIFECYCLE"
grep -Fq 'FD_CLOEXEC' "$LIFECYCLE"
grep -Fq 'SO_ACCEPTCONN' "$LIFECYCLE"
grep -Fq 'JuiceListenerOwnsFD' "$LIFECYCLE"
grep -Fq 'reused_fd=' "$LIFECYCLE"

# CLI stdin uses the same exact-write semantics as socket I/O: EINTR retries and
# hard failures close/invalidate the child pipe rather than reusing a dead fd.
grep -Fq 'JuiceCLIWriteAll' "$CLI_INPUT"
grep -Fq 'errno==EINTR' "$CLI_INPUT"
grep -Fq 'CLI_STDIN_FAILED' "$CLI_INPUT"
grep -Fq 'childInput",@(-1)' "$CLI_INPUT"

# Launches must not split quoted arguments or mutate UIKit's process cwd. The
# dedicated trace helper consumes JUICE_LAUNCH_CWD, chdirs only itself, removes
# the private variable, then spawns Wine. This avoids iOS-private spawn actions.
grep -Fq 'JuiceParseArguments' "$LAUNCH"
grep -Fq 'POSIX_SPAWN_CLOEXEC_DEFAULT' "$LAUNCH"
grep -Fq 'JUICE_LAUNCH_CWD=' "$LAUNCH"
grep -Fq 'cwd_transport=trace-parent' "$LAUNCH"
grep -Fq 'launch-setup-failed' "$LAUNCH"
grep -Fq 'JuiceLaunchStop(self,@"new-launch")' "$LAUNCH"
grep -Fq 'apply_launch_directory' "$TRACE_PARENT"
grep -Fq 'getenv("JUICE_LAUNCH_CWD")' "$TRACE_PARENT"
grep -Fq 'unsetenv("JUICE_LAUNCH_CWD")' "$TRACE_PARENT"
grep -Fq 'chdir(copy)' "$TRACE_PARENT"
if grep -Fq 'posix_spawn_file_actions_addchdir_np' "$LAUNCH"; then
  echo "UIKit launch code must not depend on unavailable iOS spawn cwd extensions." >&2
  exit 3
fi
if grep -Fq 'chdir(' "$LAUNCH"; then
  echo "UIKit launch hardening must never change the host process cwd." >&2
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

for source in JuiceSocketHardening.m JuiceHostIOHardening.m JuiceDisplayTransportHardening.m JuiceReconnectGrace.m JuiceWindowsDataImport.m JuicePointerInput.m JuiceMemoryPressure.m JuiceLifecycleHardening.m JuiceCLIInputHardening.m JuiceLaunchHardening.m; do
  grep -Fq "app/$source" "$BUILD" || { echo "build-app.sh does not compile $source" >&2; exit 3; }
done

echo "JUICE_MAINLINE_HARDENING_VERIFY_OK"
