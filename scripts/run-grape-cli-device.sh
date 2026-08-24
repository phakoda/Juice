#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GRAPE="${JUICE_GRAPE_ROOT:-$ROOT/build/runtime-stage/Grape}"
PREFIX="${JUICE_TEST_PREFIX:-$ROOT/build/test-prefix}"
LOADER="$GRAPE/build/wine-ios/loader/wine"
SERVER="$GRAPE/build/wine-ios/server/wineserver"
TRACER="$GRAPE/tools/grape-trace-parent"
NATIVE="$GRAPE/build/wine-ios/dlls"
PE_ROOT="$GRAPE/runtime/lib/wine"
PE="$GRAPE/runtime/lib/wine/aarch64-windows"
PE_I386="$GRAPE/runtime/lib/wine/i386-windows"
DATA_ROOT="${JUICE_DATA_ROOT:-/var/mobile/Documents/JuiceData}"

test -x "$LOADER" || { echo "Missing Grape loader: $LOADER" >&2; exit 2; }
test -x "$SERVER" || { echo "Missing Grape wineserver: $SERVER" >&2; exit 2; }
test -x "$TRACER" || { echo "Missing Grape trace parent: $TRACER" >&2; exit 2; }

require_runtime_marker()
{
  local path="$1" marker="$2" description="$3"
  test -s "$path" || {
    echo "Unsafe translated runtime: missing $description: $path" >&2
    exit 3
  }
  # Consume all strings output.  grep -q would close the pipe early and, with
  # pipefail, can turn a successful match into a false failure via SIGPIPE.
  LC_ALL=C strings "$path" | grep -F "$marker" >/dev/null || {
    echo "Unsafe translated runtime: $description lacks '$marker': $path" >&2
    exit 3
  }
}

# Refuse any translated launch before Wine can alter its address map unless
# this installed runtime implements the complete XNU hole-list handshake.
if test "${JUICE_EXPERIMENTAL_X64:-0}" = 1 ||
   test "${JUICE_EXPERIMENTAL_WIN32:-0}" = 1; then
  require_runtime_marker "$LOADER" JUICE_LOWVA_HOLELIST_OK "Wine loader"
  require_runtime_marker "$LOADER" JUICE_LOWVA_ATOMIC_RESERVE_OK \
    "Wine loader atomic low-VA reservation"
  require_runtime_marker "$LOADER" JUICE_LOWVA_WIN32_2G_RESERVE_OK \
    "Wine loader full Win32 2 GiB reservation"
  require_runtime_marker "$GRAPE/tools/juice-lowva-helper" holes-disabled-v1 "low-VA helper"
  require_runtime_marker "$GRAPE/build/wine-ios/dlls/ntdll/ntdll.so" JUICE_LOWVA_READY \
    "Wine ntdll Unix library"
  require_runtime_marker "$PE/ntdll.dll" NtWineRestoreCurrentTeb \
    "Wine PE ntdll TEB recovery export"
  require_runtime_marker "$PE/kernelbase.dll" NtWineRestoreCurrentTeb \
    "Wine PE kernelbase TEB recovery import"
  require_runtime_marker "$PE/user32.dll" NtWineRestoreCurrentTeb \
    "Wine PE user32 TEB recovery import"
  echo "JUICE_TRANSLATION_RUNTIME_SAFETY_OK runtime=$GRAPE protocol=holes-disabled-v4-teb-tls-recovery"
fi

prefix_needs_initialization=0
if test ! -f "$PREFIX/.juice-prefix-ready"; then
  prefix_needs_initialization=1
fi
if test ! -f "$PREFIX/system.reg"; then
  mkdir -p "$(dirname "$PREFIX")"
  rsync -a "$GRAPE/prefix-template/" "$PREFIX/"
fi
mkdir -p "$PREFIX/dosdevices"
if test ! -L "$PREFIX/dosdevices/c:" ||
   test "$(readlink "$PREFIX/dosdevices/c:" 2>/dev/null || true)" != ../drive_c; then
  rm -f "$PREFIX/dosdevices/c:"
  ln -s ../drive_c "$PREFIX/dosdevices/c:"
fi
if test ! -L "$PREFIX/dosdevices/z:" ||
   test "$(readlink "$PREFIX/dosdevices/z:" 2>/dev/null || true)" != /; then
  rm -f "$PREFIX/dosdevices/z:"
  ln -s / "$PREFIX/dosdevices/z:"
fi
mkdir -p "$PREFIX/drive_c/windows/system32"
skip_wineboot="${JUICE_SKIP_WINEBOOT:-0}"
effective_skip_wineboot="$skip_wineboot"
# A completed prefix must not pay the full wineboot cost for every CLI
# process.  JUICE_FORCE_WINEBOOT=1 remains available for an intentional
# repair/update pass on an already initialized prefix.
if test "$prefix_needs_initialization" -eq 0 &&
   test "${JUICE_FORCE_WINEBOOT:-0}" != 1; then
  effective_skip_wineboot=1
fi
if test "$prefix_needs_initialization" -eq 0 ||
   { test -n "$skip_wineboot" && test "$skip_wineboot" != 0; }; then
  for module in "$PE"/*.dll "$PE"/*.exe "$PE"/*.drv; do
    test -f "$module" || continue
    destination="$PREFIX/drive_c/windows/system32/$(basename "$module")"
    case "$(basename "$module")" in
      JuiceGUI.exe|JuiceTextSmoke.exe|winemine.exe|x86_64-smoke.exe)
        if test -e "$destination" || test -L "$destination"; then
          rm -f "$destination"
        fi
        ln -s "$module" "$destination"
        ;;
    *) if test -L "$destination"; then
      ln -sfn "$module" "$destination"
    elif test ! -e "$destination"; then
      ln -s "$module" "$destination"
    fi ;;
    esac
  done
else
  echo "JUICE_PREFIX_BOOTSTRAP mode=wineboot runtime_links=deferred prefix=$PREFIX"
fi

if test "${JUICE_EXPERIMENTAL_X64:-0}" = 1 ||
   test "${JUICE_EXPERIMENTAL_WIN32:-0}" = 1; then
  test -s "$PE/libarm64ecfex.dll" || {
    echo "Missing x86-64 translator: $PE/libarm64ecfex.dll" >&2
    exit 2
  }
fi

if test "${JUICE_EXPERIMENTAL_WIN32:-0}" = 1; then
  test -s "$PE/libwow64fex.dll" || {
    echo "Missing Legacy Win32 translator: $PE/libwow64fex.dll" >&2
    exit 2
  }
  test -s "$PE_I386/ntdll.dll" || {
    echo "Missing Legacy Win32 PE runtime: $PE_I386/ntdll.dll" >&2
    exit 2
  }
  mkdir -p "$PREFIX/drive_c/windows/syswow64"
  linked_i386=0
  for module in "$PE_I386"/*.dll "$PE_I386"/*.exe "$PE_I386"/*.drv; do
    test -f "$module" || continue
    destination="$PREFIX/drive_c/windows/syswow64/$(basename "$module")"
    if test -L "$destination"; then
      ln -sfn "$module" "$destination"
    elif test ! -e "$destination"; then
      ln -s "$module" "$destination"
    fi
    linked_i386=$((linked_i386 + 1))
  done
  echo "JUICE_WIN32_RUNTIME_LINKS count=$linked_i386 syswow64=$PREFIX/drive_c/windows/syswow64"
fi

export TMPDIR="${TMPDIR:-/tmp}"
export WINEPREFIX="$PREFIX"
export WINELOADER="$GRAPE/tools/grape-nested-wrapper"
export WINELOADERNOEXEC=1
export WINESERVER="$SERVER"
# Point Wine at the multi-architecture root first.  Wine appends
# aarch64-windows or i386-windows while resolving a module.  Putting the
# aarch64 leaf first lets a WoW64 lookup fall through to the hybrid ARM64
# kernel32.dll and fail with STATUS_INVALID_IMAGE_FORMAT (c000007b).
winedllpath="$PE_ROOT:$NATIVE/crypt32:$NATIVE/dnsapi:$NATIVE/secur32:$NATIVE/wineios.drv:$NATIVE/winevulkan:$NATIVE/win32u:$NATIVE/ws2_32"
if test "${JUICE_EXPERIMENTAL_X64:-0}" = 1 ||
   test "${JUICE_EXPERIMENTAL_WIN32:-0}" = 1; then
  export HODLL64="${HODLL64:-libarm64ecfex.dll}"
  export JUICE_EXPERIMENTAL_X64=1
fi
if test "${JUICE_EXPERIMENTAL_WIN32:-0}" = 1; then
  export HODLL="${HODLL:-libwow64fex.dll}"
fi
export WINEDLLPATH="$winedllpath"
export DYLD_LIBRARY_PATH="${DYLD_LIBRARY_PATH:-/var/jb/usr/lib}"
bundle_ca="$(dirname "$GRAPE")/Libraries/ca-certificates.pem"
if test -s "$bundle_ca"; then
  export JUICE_CA_BUNDLE="${JUICE_CA_BUNDLE:-$bundle_ca}"
  export SSL_CERT_FILE="${SSL_CERT_FILE:-$bundle_ca}"
fi
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:--all}"
export JUICE_SKIP_WINEBOOT="$effective_skip_wineboot"
export JUICE_WINESERVER_ROOT="${JUICE_WINESERVER_ROOT:-$DATA_ROOT/wineserver}"
export PATH="/usr/bin:/bin:${PATH:-}"
mkdir -p "$JUICE_WINESERVER_ROOT"
chmod 700 "$JUICE_WINESERVER_ROOT"

server_pid=-1
client_pid=-1
# Monitor mode gives each background job its own process group even in this
# non-interactive device shell. This lets cleanup terminate Wine's nested
# wrappers as well as their immediate parent when a bounded test is cancelled.
set -m
"$SERVER" -f &
server_pid=$!
set +m
cleanup()
{
  if test "$client_pid" -gt 0; then
    kill -TERM "-$client_pid" 2>/dev/null || kill -TERM "$client_pid" 2>/dev/null || true
  fi
  # Ask the prefix's server to terminate every registered Wine client before
  # reaping the foreground server.  Service processes daemonize during
  # wineboot and otherwise survive short CLI smoke-test invocations on iOS.
  "$SERVER" -k 2>/dev/null || true
  # Give wineserver a bounded grace period to flush registry changes.  Killing
  # it immediately loses newly imported trust roots and installer registry
  # state on persistent iOS prefixes.
  timeout 5 "$SERVER" -w 2>/dev/null || true
  kill -TERM "-$server_pid" 2>/dev/null || kill -TERM "$server_pid" 2>/dev/null || true
  sleep 1
  if test "$client_pid" -gt 0; then
    kill -KILL "-$client_pid" 2>/dev/null || kill -KILL "$client_pid" 2>/dev/null || true
    wait "$client_pid" 2>/dev/null || true
  fi
  kill -KILL "-$server_pid" 2>/dev/null || kill -KILL "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1
set +e
set -m
"$TRACER" "$LOADER" "$@" &
client_pid=$!
set +m
wait "$client_pid"
client_status=$?
set -e
exit "$client_status"
