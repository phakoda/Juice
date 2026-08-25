#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GRAPE="${JUICE_X64_GRAPE_ROOT:-$ROOT/build/x86_64-runtime-stage/Grape-X64}"
PREFIX="${JUICE_X86_PREFIX:-/var/mobile/Documents/JuiceData/GrapePrefix-x86_64}"
MARKER="${JUICE_X86_MARKER:-/var/mobile/Documents/Juice-x86-smoke.ok}"
LOG="${JUICE_X86_LOG:-/var/mobile/Documents/Juice-x86-smoke.log}"
SOCKET="${JUICE_IOS_SOCKET:-/var/mobile/Documents/JuiceData/juice.sock}"
LOADER="$GRAPE/build/wine-ios/loader/wine"
SERVER="$GRAPE/build/wine-ios/server/wineserver"
TRACER="$GRAPE/tools/grape-trace-parent"
PE64="$GRAPE/runtime/lib/wine/aarch64-windows"
PE32="$GRAPE/runtime/lib/wine/i386-windows"
NATIVE="$GRAPE/build/wine-ios/dlls"
SMOKE="$GRAPE/tests/x86-smoke.exe"
TRANSLATOR="$PE64/libwow64fex.dll"

test "$(uname -s)" = Darwin || { echo "This smoke runner must execute on the iPad." >&2; exit 2; }
for path in "$LOADER" "$SERVER" "$TRACER" "$SMOKE" "$TRANSLATOR" "$PE32/ntdll.dll"; do
  test -e "$path" || { echo "Missing Win32 smoke dependency: $path" >&2; exit 2; }
done

if test ! -f "$PREFIX/system.reg"; then
  mkdir -p "$(dirname "$PREFIX")"
  rsync -a "$GRAPE/prefix-template/" "$PREFIX/"
fi
mkdir -p "$PREFIX/dosdevices" /var/mobile/Documents/JuiceData/tmp \
  "$PREFIX/drive_c/windows/system32" "$PREFIX/drive_c/windows/syswow64"
if test ! -e "$PREFIX/dosdevices/z:" && test ! -L "$PREFIX/dosdevices/z:"; then
  ln -s / "$PREFIX/dosdevices/z:"
fi

for module in "$PE64"/*.dll "$PE64"/*.exe "$PE64"/*.drv; do
  test -f "$module" || continue
  destination="$PREFIX/drive_c/windows/system32/$(basename "$module")"
  if test -L "$destination"; then
    ln -sfn "$module" "$destination"
  elif test ! -e "$destination"; then
    ln -s "$module" "$destination"
  fi
done
for module in "$PE32"/*.dll "$PE32"/*.exe "$PE32"/*.drv "$PE32"/*.sys; do
  test -f "$module" || continue
  destination="$PREFIX/drive_c/windows/syswow64/$(basename "$module")"
  if test -L "$destination"; then
    ln -sfn "$module" "$destination"
  elif test ! -e "$destination"; then
    ln -s "$module" "$destination"
  fi
done

rm -f "$MARKER"
case "$MARKER" in
  /*) export JUICE_X86_MARKER_WINDOWS="Z:${MARKER//\//\\}" ;;
  *) echo "JUICE_X86_MARKER must be an absolute Unix path: $MARKER" >&2; exit 2 ;;
esac

export HOME=/var/mobile
export TMPDIR=/var/mobile/Documents/JuiceData/tmp
export WINEPREFIX="$PREFIX"
export WINELOADER="$GRAPE/tools/grape-nested-wrapper"
export WINESERVER="$SERVER"
export WINEDLLPATH="$PE64:$NATIVE/crypt32:$NATIVE/wineios.drv:$NATIVE/win32u:$NATIVE/ws2_32"
export DYLD_LIBRARY_PATH="${DYLD_LIBRARY_PATH:-/var/jb/usr/lib}"
export JUICE_IOS_SOCKET="$SOCKET"
export JUICE_SKIP_WINEBOOT="${JUICE_SKIP_WINEBOOT:-1}"
export JUICE_EXPERIMENTAL_X64=1
export JUICE_EXPERIMENTAL_WIN32=1
export HODLL64=libarm64ecfex.dll
export HODLL=libwow64fex.dll
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:--all}"
export PATH="/var/jb/usr/bin:/usr/bin:/bin"
if test "${JUICE_X86_SMOKE_HEADLESS:-1}" = 1; then
  export JUICE_X86_SMOKE_HEADLESS=1
else
  unset JUICE_X86_SMOKE_HEADLESS
fi

: >"$LOG"
"$SERVER" -f >>"$LOG" 2>&1 &
server_pid=$!
cleanup()
{
  "$SERVER" -k >/dev/null 2>&1 || true
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1

set +e
timeout "${JUICE_X86_TIMEOUT_SECONDS:-45}" "$TRACER" "$LOADER" "$SMOKE" >>"$LOG" 2>&1
status=$?
set -e

test -s "$MARKER" || {
  echo "X86_SMOKE_FAILED status=$status marker=$MARKER log=$LOG" >&2
  tail -n 120 "$LOG" >&2 || true
  exit 3
}
grep -Fq "JUICE_X86_SMOKE_OK" "$MARKER"
sha256sum "$SMOKE" "$TRANSLATOR" "$PE32/ntdll.dll" "$MARKER"
echo "JUICE_X86_DEVICE_SMOKE_OK status=$status marker=$MARKER log=$LOG"
