#!/usr/bin/env bash
# Compile catalogued Wine builtin DLLs. This is not a full iOS runtime/package.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ARCH="${1:-aarch64}"
case "$ARCH" in aarch64|arm64ec|i386) ;; *) echo 'Expected aarch64, arm64ec, or i386.' >&2; exit 2;; esac
test "$(uname -s)" = Linux || { echo 'This PE validation requires Linux.' >&2; exit 2; }
source "$ROOT/config/x86_64-build.env"
BUILD="$ROOT/build/graphics-api-$ARCH"
LOG="$ROOT/build/graphics-api-logs/$ARCH"
mkdir -p "$BUILD" "$LOG"
python3 "$ROOT/scripts/verify_graphics_api.py" > "$LOG/source-audit.json"
bash "$ROOT/scripts/apply-wine-stikdebug-jit.sh"
bash "$ROOT/scripts/bootstrap-x86_64-toolchain-linux.sh"
bash "$ROOT/scripts/build-wine-tools-linux.sh" 2>&1 | tee "$LOG/host-tools.log"
TOOLCHAIN="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}/$JUICE_LLVM_MINGW_DIRNAME"
TRIPLE_ARCH="$ARCH"
if test "$ARCH" = i386; then TRIPLE_ARCH=i686; fi
export JUICE_REAL_PE_CLANG="$TOOLCHAIN/bin/$TRIPLE_ARCH-w64-mingw32-clang"
export JUICE_PE_WRAPPER="$ROOT/build/graphics-api-$ARCH-tools/clang"
export JUICE_PYTHON="$(command -v python3)" JUICE_INCBIN_PACKER="$ROOT/toolchain/juice-pack-incbins.py"
bash "$ROOT/scripts/build-pe-compiler-wrapper-linux.sh"
export PATH="$TOOLCHAIN/bin:$PATH"
# The native side is only used for build-host generators. Target DLLs use the
# same pinned PE compiler/resource wrapper as production, with no target exec.
(cd "$BUILD"; CC=clang CXX=clang++ "$ROOT/wine/configure" \
  --enable-archs="$ARCH" --disable-tests --disable-win16 \
  --with-wine-tools="${JUICE_WINE_TOOLS_BUILD:-$ROOT/build/wine-tools-linux}" \
  --with-mingw="$JUICE_PE_WRAPPER" \
  --without-x --without-wayland --without-coreaudio --without-cups --without-dbus \
  --without-ffmpeg --without-fontconfig --without-freetype --without-gettext \
  --without-gphoto --without-gnutls --without-gssapi --without-gstreamer \
  --without-krb5 --without-netapi --without-opencl --without-opengl --without-oss \
  --without-pcap --without-pcsclite --without-pulse --without-sane --without-sdl \
  --without-udev --without-usb --without-v4l2 --with-vulkan) 2>&1 | tee "$LOG/configure.log"
python3 "$ROOT/scripts/verify_graphics_api.py" --build "$BUILD" --arch "$ARCH" --targets > "$LOG/targets.txt"
mapfile -t targets < "$LOG/targets.txt"
test "${#targets[@]}" -gt 0
# Exercise the external build-host template generator before the large DLL
# matrix. D3DX consumes this header even when Wine's basic host tools compiled.
make -C "$BUILD" include/rmxftmpl.h 2>&1 | tee "$LOG/template-header.log"
test -s "$BUILD/include/rmxftmpl.h"
make --output-sync=target -C "$BUILD" -j"${JUICE_JOBS:-2}" "${targets[@]}" 2>&1 | tee "$LOG/build.log"
python3 "$ROOT/scripts/verify_graphics_api.py" --build "$BUILD" --arch "$ARCH" > "$LOG/built-modules.json"
echo "JUICE_GRAPHICS_API_PE_COMPILE_OK arch=$ARCH modules=${#targets[@]} linked_ios_runtime=0 device_test=0"
