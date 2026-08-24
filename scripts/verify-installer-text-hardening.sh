#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TEXT="$ROOT/app/JuiceTextInputHardening.m"
MSI="$ROOT/app/JuiceMSIImport.m"
KEYBOARD="$ROOT/app/JuiceHardwareKeyboard.m"

for path in "$TEXT" "$MSI" "$KEYBOARD"; do
  test -f "$path" || { echo "Missing installer/text hardening source: $path" >&2; exit 2; }
  grep -Fq "app/$(basename "$path")" "$ROOT/scripts/build-app.sh" || {
    echo "build-app.sh does not compile $path" >&2
    exit 3
  }
done

# Wine rejects input payloads above 64 KiB. Keep host text chunks below that
# limit and bound an individual paste so it cannot monopolize the control pipe.
grep -Fq '#define JUICE_TEXT_CHUNK_BYTES (60u * 1024u)' "$TEXT"
grep -Fq '#define JUICE_TEXT_MAX_PASTE_BYTES (1024u * 1024u)' "$TEXT"
grep -Fq 'NSUTF16LittleEndianStringEncoding' "$TEXT"
grep -Fq 'Paste iOS Clipboard into Windows' "$TEXT"
grep -Fq 'chunks=%lu delivered=%d' "$TEXT"
grep -Fq 'juice_pasteIOSClipboard:' "$KEYBOARD"
grep -Fq 'modifiers == UIKeyModifierCommand' "$KEYBOARD"

# Direct MSI selection must use the packaged Wine installer through the normal
# hardened launch path rather than trying to execute the MSI as a PE image.
grep -Fq 'msiexec.exe' "$ROOT/config/runtime-modules.txt"
grep -Fq 'msi.dll' "$ROOT/config/runtime-modules.txt"
grep -Fq 'exe.text = @"msiexec.exe"' "$MSI"
grep -Fq '@"/i \\"%@\\""' "$MSI"
grep -Fq 'Choose EXE, MSI or Portable ZIP' "$MSI"
grep -Fq 'launchRequested' "$MSI"

echo "JUICE_INSTALLER_TEXT_HARDENING_VERIFY_OK"
