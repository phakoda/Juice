#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test "$(uname -s)" = Darwin || { echo 'This validation requires the Xcode iPhoneOS SDK.' >&2; exit 2; }
export IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)" JUICE_COMPILE_ROOT="$ROOT" JUICE_IOS_DEVICE=1
# Reuse the production-target configure and generated headers. This also
# validates the native JIT, loader and server objects with the same SDK.
bash "$ROOT/scripts/test-wine-ios-compile.sh"
TARGET="$ROOT/build/wine-ios-validation"
make -C "$TARGET" -j2 dlls/wineios.drv/iosdrv.o dlls/wineios.drv/vulkan.o \
  dlls/wineios.drv/ipc.o dlls/wineios.drv/control.o 2>&1 | tee "$ROOT/build/wine-compile-logs/ios-graphics.log"
for name in iosdrv vulkan ipc control; do
  file "$TARGET/dlls/wineios.drv/$name.o" | grep -q 'Mach-O 64-bit.*arm64'
done
echo 'JUICE_WINE_GRAPHICS_IOS_COMPILE_OK driver_objects=4 linked_runtime=0 device_test=0'
