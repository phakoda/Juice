#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test "$(uname -s)" = Linux || { echo 'The full SideStore cross-build requires Linux.' >&2; exit 2; }
cd "$ROOT"
export JUICE_JOBS="${JUICE_JOBS:-2}"
export JUICE_WINE_BUILD="$ROOT/build/sidestore/native"
export JUICE_PE_BUILD="$ROOT/build/sidestore/arm64-pe"
export JUICE_ARM64EC_PE_BUILD="$ROOT/build/sidestore/hybrid-pe"
export JUICE_FEX_BUILD="$ROOT/build/sidestore/fex-arm64ec"
export JUICE_STATIC_FREETYPE_BUILD="$ROOT/build/sidestore/freetype"
export JUICE_WINE_TOOLS_BUILD="$ROOT/build/sidestore/wine-tools"
export JUICE_APP_BUILD_DIR="$ROOT/build/sidestore/app/Juice.app"
export JUICE_BUILD_LOG_DIR="$ROOT/build/sidestore/logs"
mkdir -p "$JUICE_BUILD_LOG_DIR" dist

stage()
{
  local name="$1"; shift
  echo "::group::SideStore — $name"
  "$@" 2>&1 | tee "$JUICE_BUILD_LOG_DIR/$name.log"
  echo '::endgroup::'
}
stage cross-toolchain make linux-x86_64-preflight
export IOS_SDK="${IOS_SDK:-$(bash scripts/fetch-ios-sdk-linux.sh --print-path)}"
export JUICE_IOS_TOOLCHAIN="${JUICE_IOS_TOOLCHAIN:-$ROOT/build/ios-toolchain}"
export JUICE_IOS_ROOTLESS_SYSROOT="${JUICE_IOS_ROOTLESS_SYSROOT:-$ROOT/build/deps/rootless-sysroot}"
stage support bash scripts/build-embedded-support.sh
stage app env JUICE_SIDESTORE=1 JUICE_EMBEDDED=0 bash scripts/build-app.sh
stage wine-patches bash scripts/apply-wine-embedded.sh
stage host-tools env JUICE_EMBEDDED=0 bash scripts/build-wine-tools-linux.sh
export JUICE_EMBEDDED=1
stage freetype bash scripts/prepare-static-freetype-wine-linux.sh
stage pe-configure bash scripts/configure-wine-pe-linux.sh
stage native-and-arm64 bash scripts/build-wine-linux.sh
stage fex bash scripts/build-fex-arm64ec-linux.sh
stage hybrid bash scripts/build-wine-arm64ec-linux.sh
stage package python3 scripts/sidestore_package.py \
  --output "$ROOT/dist/Juice-SideStore-$(git rev-parse --short=12 HEAD).ipa"
