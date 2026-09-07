#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test "$(uname -s)" = Darwin || { echo 'The embedded Wine Xcode gate requires macOS.' >&2; exit 2; }
if command -v brew >/dev/null 2>&1; then
  bison_prefix="$(brew --prefix bison 2>/dev/null || true)"
  if test -x "$bison_prefix/bin/bison"; then export PATH="$bison_prefix/bin:$PATH"; fi
fi
WORK="$ROOT/build/sidestore-xcode"
SOURCE="$WORK/wine"
TOOLS="$WORK/tools"
TARGET="$WORK/native"
LOG="$WORK/logs"
mkdir -p "$SOURCE" "$TOOLS" "$TARGET" "$LOG"
mkdir -p "$WORK/tests/input"
cp "$ROOT/tests/input/smoke.c" "$WORK/tests/input/smoke.c"
# Isolate optional patches from the checkout and any simultaneous legacy build.
rsync -a --exclude=.git "$ROOT/wine/" "$SOURCE/"
JUICE_WINE_SOURCE="$SOURCE" bash "$ROOT/scripts/apply-wine-embedded.sh"
mkdir -p "$SOURCE/include/juice"
cp "$ROOT/runtime/embedded/JuiceEmbeddedRuntime.h" "$ROOT/runtime/embedded/JuiceEmbeddedShim.h" "$SOURCE/include/juice/"
bash "$ROOT/scripts/build-embedded-support.sh"
options=(--enable-archs=none --disable-tests --disable-win16 --without-mingw
  --without-x --without-wayland --without-coreaudio --without-cups --without-dbus
  --without-ffmpeg --without-fontconfig --without-freetype --without-gettext
  --without-gphoto --without-gnutls --without-gssapi --without-gstreamer
  --without-krb5 --without-netapi --without-opencl --without-opengl --without-oss
  --without-pcap --without-pcsclite --without-pulse --without-sane --without-sdl
  --without-udev --without-usb --without-v4l2 --without-vulkan)
if test ! -f "$TOOLS/Makefile"; then
  (cd "$TOOLS"; CC=clang CXX=clang++ "$SOURCE/configure" "${options[@]}") > "$LOG/host-configure.log" 2>&1
fi
make -C "$TOOLS" -j2 tools/makedep tools/make_xftmpl tools/winebuild/winebuild tools/winegcc/winegcc \
  tools/widl/widl tools/wrc/wrc tools/wmc/wmc > "$LOG/host-tools.log" 2>&1
cat > "$TARGET/ios-cc" <<'WRAPPER'
#!/bin/bash
set -euo pipefail
extra=(-target arm64-apple-ios14.0 -isysroot "$IOS_SDK" -DJUICE_EMBEDDED=1 -I"$JUICE_COMPILE_ROOT/runtime/embedded")
for arg in "$@"; do
  case "$arg" in
    */dlls/*/*.so|dlls/*/*.so)
      extra+=(-F"$JUICE_COMPILE_ROOT/build/sidestore/frameworks" -framework JuiceRuntimeSupport -Wl,-headerpad_max_install_names);;
    */server/wineserver|server/wineserver)
      extra+=(-dynamiclib -F"$JUICE_COMPILE_ROOT/build/sidestore/frameworks" -framework JuiceRuntimeSupport \
        -Wl,-headerpad_max_install_names -Wl,-install_name,@rpath/JuiceWineServer.framework/JuiceWineServer);;
  esac
done
exec xcrun --sdk iphoneos clang "${extra[@]}" "$@"
WRAPPER
chmod +x "$TARGET/ios-cc"
export IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)" JUICE_COMPILE_ROOT="$ROOT" JUICE_IOS_DEVICE=1
export wine_cv_64bit_compare_swap='none needed' ac_cv_func_pthread_create=yes
if test ! -f "$TARGET/Makefile"; then
  (cd "$TARGET"; CC="$TARGET/ios-cc" CXX="$TARGET/ios-cc" OBJC="$TARGET/ios-cc" \
    "$SOURCE/configure" --build="$("$SOURCE/tools/config.guess")" --host=aarch64-apple-darwin \
      --with-wine-tools="$TOOLS" "${options[@]}") > "$LOG/ios-configure.log" 2>&1
fi
make -C "$TARGET" -j2 dlls/ntdll/ntdll.so server/wineserver \
  dlls/wineios.drv/iosdrv.o dlls/wineios.drv/vulkan.o dlls/wineios.drv/ipc.o \
  dlls/wineios.drv/control.o > "$LOG/embedded-native.log" 2>&1
python3 - "$ROOT" "$TARGET" <<'PY'
from pathlib import Path
import sys
root, target = map(Path, sys.argv[1:])
sys.path.insert(0, str(root / 'scripts'))
from sidestore_package import macho, symbols, FORBIDDEN_IMPORTS, WINE_HOST_MUTATIONS
for relative, exports in [('dlls/ntdll/ntdll.so', {'_JuiceEmbeddedWineABI', '_JuiceEmbeddedWineMain'}),
                          ('server/wineserver', {'_JuiceEmbeddedWineServerABI', '_JuiceEmbeddedWineServerMain'})]:
    data = (target / relative).read_bytes()
    assert macho(data)[0][3] == 6, relative
    imported, defined = symbols(data)
    assert exports <= defined, (relative, exports - defined)
    assert not (imported & (FORBIDDEN_IMPORTS | WINE_HOST_MUTATIONS)), (relative, imported & (FORBIDDEN_IMPORTS | WINE_HOST_MUTATIONS))
print('JUICE_EMBEDDED_WINE_XCODE_LINK_OK ntdll=1 server=1 shared_libraries=1 child_process_imports=0')
PY
