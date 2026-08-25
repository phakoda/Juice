#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

for path in app/JuiceReconnectGrace.m wine/dlls/wineios.drv/ipc.c scripts/build-app.sh; do
  test -f "$ROOT/$path" || { echo "Missing reconnect-hardening source: $path" >&2; exit 2; }
done

grep -Fq 'app/JuiceReconnectGrace.m' "$ROOT/scripts/build-app.sh"
grep -Fq 'DISPLAY_RECONNECT_GRACE' "$ROOT/app/JuiceReconnectGrace.m"
grep -Fq 'DISPLAY_RECONNECT_GRACE_END' "$ROOT/app/JuiceReconnectGrace.m"
grep -Fq 'constructor(200)' "$ROOT/app/JuiceReconnectGrace.m"
grep -Fq 'presentFrameMessage:' "$ROOT/app/JuiceReconnectGrace.m"

# Wine reconnects the display socket on demand and forces a full framebuffer
# baseline for every HWND in each new connection generation.
grep -Fq 'connect_ipc_locked' "$ROOT/wine/dlls/wineios.drv/ipc.c"
grep -Fq 'ipc_generation' "$ROOT/wine/dlls/wineios.drv/ipc.c"
grep -Fq 'surface_has_baseline_locked' "$ROOT/wine/dlls/wineios.drv/ipc.c"
grep -Fq 'available==0' "$ROOT/wine/dlls/wineios.drv/ipc.c"
grep -Fq 'writev_all' "$ROOT/wine/dlls/wineios.drv/ipc.c"

# Virtual keys are real hardware key down/up events. Modifier-capable messages
# extend that path without changing ordinary low-16-bit key taps.
grep -Fq 'input.type=INPUT_KEYBOARD' "$ROOT/wine/dlls/wineios.drv/ipc.c"
grep -Fq 'KEYEVENTF_KEYUP' "$ROOT/wine/dlls/wineios.drv/ipc.c"
grep -Fq 'send_virtual_key(target,vkey,msg.flags)' "$ROOT/wine/dlls/wineios.drv/ipc.c"

echo "JUICE_RECONNECT_HARDENING_VERIFY_OK"
