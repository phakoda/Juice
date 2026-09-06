#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test "$(uname -s)" = Darwin || { echo 'This validation uses the Xcode iPhoneOS SDK on macOS.' >&2; exit 2; }
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TOOLS="$ROOT/build/wine-tools-macos"
TARGET="$ROOT/build/wine-ios-validation"
LOG="$ROOT/build/wine-compile-logs"
mkdir -p "$TOOLS" "$TARGET" "$LOG"
bash "$ROOT/scripts/apply-wine-stikdebug-jit.sh"
options=(--enable-archs=none --disable-tests --disable-win16 --without-mingw
  --without-x --without-wayland --without-coreaudio --without-cups --without-dbus
  --without-ffmpeg --without-fontconfig --without-freetype --without-gettext
  --without-gphoto --without-gnutls --without-gssapi --without-gstreamer
  --without-krb5 --without-netapi --without-opencl --without-opengl --without-oss
  --without-pcap --without-pcsclite --without-pulse --without-sane --without-sdl
  --without-udev --without-usb --without-v4l2 --without-vulkan)
(cd "$TOOLS"; CC=clang CXX=clang++ "$ROOT/wine/configure" "${options[@]}") 2>&1 | tee "$LOG/host-configure.log"
make -C "$TOOLS" -j2 tools/makedep tools/winebuild/winebuild tools/winegcc/winegcc \
  tools/widl/widl tools/wrc/wrc tools/wmc/wmc 2>&1 | tee "$LOG/host-tools.log"
# Apply the same translation-unit-specific low-VA shim as the production Linux
# cross compiler, but use Xcode directly instead of distributing an SDK.
cat > "$TARGET/ios-cc" <<'WRAPPER'
#!/bin/bash
set -euo pipefail
extra=()
for arg in "$@"; do
  case "$arg" in
    */dlls/ntdll/unix/virtual.c) extra=(-include "$JUICE_COMPILE_ROOT/toolchain/juice-ios-map-tryfixed.h");;
    */loader/main.c) extra=(-DJUICE_IOS_LOWVA_BOOTSTRAP=1 -include "$JUICE_COMPILE_ROOT/toolchain/juice-ios-lowva-bootstrap.h");;
  esac
done
exec xcrun --sdk iphoneos clang -target arm64-apple-ios14.0 -isysroot "$IOS_SDK" "${extra[@]}" "$@"
WRAPPER
chmod +x "$TARGET/ios-cc"
export IOS_SDK="$SDK" JUICE_COMPILE_ROOT="$ROOT" JUICE_IOS_DEVICE=1
export wine_cv_64bit_compare_swap='none needed' ac_cv_func_pthread_create=yes
(cd "$TARGET"; CC="$TARGET/ios-cc" CXX="$TARGET/ios-cc" \
  "$ROOT/wine/configure" --build="$("$ROOT/wine/tools/config.guess")" \
  --host=aarch64-apple-darwin --with-wine-tools="$TOOLS" "${options[@]}") 2>&1 | tee "$LOG/ios-configure.log"
# Compile the real platform translation units, not a stubbed allocator. Linking
# a complete distributable runtime (fonts/TLS/graphics/translators) is a separate
# packaging gate; this check specifically catches native JIT/ABI source errors.
make -C "$TARGET" -j2 dlls/ntdll/unix/virtual.o dlls/ntdll/unix/signal_arm64.o \
  loader/main.o server/main.o 2>&1 | tee "$LOG/ios-objects.log"
for object in dlls/ntdll/unix/virtual.o dlls/ntdll/unix/signal_arm64.o loader/main.o server/main.o; do
  file "$TARGET/$object" | grep -q 'Mach-O 64-bit.*arm64'
done
echo 'JUICE_WINE_IOS_COMPILE_OK ntdll_virtual=1 ntdll_signal=1 loader=1 server=1 linked_runtime=0'
