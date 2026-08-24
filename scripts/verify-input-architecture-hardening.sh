#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
KEYBOARD="$ROOT/app/JuiceHardwareKeyboard.m"
ARCH="$ROOT/app/JuiceArchitectureRouting.m"
BUILD="$ROOT/scripts/build-app.sh"

for path in "$KEYBOARD" "$ARCH" "$BUILD"; do
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
grep -Fq 'UIKeyModifierCommand | UIKeyModifierControl | UIKeyModifierAlternate' "$KEYBOARD"
grep -Fq 'class_addMethod' "$KEYBOARD"

echo "JUICE_INPUT_ARCHITECTURE_HARDENING_VERIFY_OK"
