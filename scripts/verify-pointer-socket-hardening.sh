#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
POINTER="$ROOT/app/JuicePointerInput.m"
SOCKET="$ROOT/app/JuiceSocketHardening.m"
BUILD="$ROOT/scripts/build-app.sh"

for path in "$POINTER" "$SOCKET"; do
  test -f "$path" || { echo "Missing pointer/socket hardening source: $path" >&2; exit 2; }
done
for source in JuicePointerInput.m JuiceSocketHardening.m; do
  grep -Fq "app/$source" "$BUILD" || {
    echo "build-app.sh does not compile $source" >&2
    exit 3
  }
done

# iPad mouse/trackpad use must not require toggling the manual right-click mode.
grep -Fq 'UIHoverGestureRecognizer' "$POINTER"
grep -Fq 'UITouchTypeIndirectPointer' "$POINTER"
grep -Fq 'UIEventButtonMaskSecondary' "$POINTER"
grep -Fq 'handleCanvasInput:' "$POINTER"
grep -Fq 'physical_secondary_click=1' "$POINTER"

# Listener/client sockets should never leak into Wine children and transient
# descriptor pressure must not permanently kill display/control accept loops.
grep -Fq 'FD_CLOEXEC' "$SOCKET"
grep -Fq 'SO_NOSIGPIPE' "$SOCKET"
grep -Fq 'JuiceTransientAcceptError' "$SOCKET"
grep -Fq 'SOCKET_ACCEPT_RETRY' "$SOCKET"
grep -Fq 'restart_on_foreground=1' "$SOCKET"
grep -Fq 'current != listener' "$SOCKET"

echo "JUICE_POINTER_SOCKET_HARDENING_VERIFY_OK"
