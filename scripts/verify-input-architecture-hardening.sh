#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
KEYBOARD="$ROOT/app/JuiceHardwareKeyboard.m"
ARCH="$ROOT/app/JuiceArchitectureRouting.m"
IPC_H="$ROOT/wine/dlls/wineios.drv/ipc.h"
IPC_C="$ROOT/wine/dlls/wineios.drv/ipc.c"
BUILD="$ROOT/scripts/build-app.sh"

for path in "$KEYBOARD" "$ARCH" "$IPC_H" "$IPC_C" "$BUILD"; do
  test -f "$path" || { echo "Missing input/architecture hardening source: $path" >&2; exit 2; }
done

grep -Fq 'app/JuiceHardwareKeyboard.m' "$BUILD"
if grep -Fq 'app/JuiceLegacyWin32.m' "$BUILD"; then
  echo "Legacy Win32 hook must not compete with JuiceArchitectureRouting in the app binary." >&2
  exit 3
fi

grep -Fq 'constructor(300)' "$ARCH"
grep -Fq 'runtime/lib/wine/i386-windows/kernel32.dll' "$ARCH"
grep -Fq 'HODLL=libwow64fex.dll' "$ARCH"

grep -Fq 'pressesBegan:withEvent:' "$KEYBOARD"
grep -Fq 'dataUsingEncoding:NSUTF16LittleEndianStringEncoding' "$KEYBOARD"
grep -Fq 'JuiceVirtualKeyForHID' "$KEYBOARD"
grep -Fq 'case 0x29: key = 0x1b' "$KEYBOARD"
grep -Fq 'case 0x4f: key = 0x27' "$KEYBOARD"
grep -Fq 'JUICE_KEY_SHIFT' "$KEYBOARD"
grep -Fq 'JUICE_KEY_CONTROL' "$KEYBOARD"
grep -Fq 'JUICE_KEY_ALT' "$KEYBOARD"
grep -Fq 'JuiceCommandShortcutShouldReachWine' "$KEYBOARD"
grep -Fq 'JuicePasteIOSClipboard' "$KEYBOARD"
grep -Fq 'class_addMethod' "$KEYBOARD"

# The wire protocol keeps low-16-bit virtual-key compatibility while allowing
# atomic modifier-down/key-tap/modifier-up chords for desktop keyboard use.
grep -Fq 'JUICE_IOS_KEY_SHIFT' "$IPC_H"
grep -Fq 'JUICE_IOS_KEY_CONTROL' "$IPC_H"
grep -Fq 'JUICE_IOS_KEY_ALT' "$IPC_H"
grep -Fq 'send_key_event(target,VK_CONTROL,0)' "$IPC_C"
grep -Fq 'send_key_event(target,VK_MENU,0)' "$IPC_C"
grep -Fq 'send_virtual_key(target,vkey,msg.flags)' "$IPC_C"
grep -Fq 'modifiers=%x' "$IPC_C"

echo "JUICE_INPUT_ARCHITECTURE_HARDENING_VERIFY_OK"
