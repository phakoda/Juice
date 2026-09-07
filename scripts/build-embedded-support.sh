#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$ROOT/build/sidestore/frameworks/JuiceRuntimeSupport.framework"
mkdir -p "$OUT"
flags=()
if command -v xcrun >/dev/null 2>&1; then
  SDK="${IOS_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
  COMPILER="$(xcrun --sdk iphoneos --find clang)"
  flags=(-target "arm64-apple-ios${JUICE_MIN_IOS:-14.0}" -isysroot "$SDK")
else
  COMPILER="$ROOT/toolchain/juice-ios-cc"
fi
# The support library implements the boundary, so must NEVER compile with its
# own Wine symbol substitutions or inject its own framework recursively.
JUICE_EMBEDDED=0 "$COMPILER" "${flags[@]}" -std=gnu11 -O2 -fPIC -Wall -Wextra -Werror \
  -dynamiclib -Wl,-headerpad_max_install_names \
  -Wl,-install_name,@rpath/JuiceRuntimeSupport.framework/JuiceRuntimeSupport \
  "$ROOT/runtime/embedded/JuiceEmbeddedRuntime.c" \
  "$ROOT/runtime/embedded/JuiceEmbeddedMemory.c" \
  "$ROOT/runtime/embedded/JuiceEmbeddedPolicy.c" -o "$OUT/JuiceRuntimeSupport"
python3 - "$OUT/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "org.juice.runtime.JuiceRuntimeSupport",
    "CFBundleExecutable": "JuiceRuntimeSupport", "CFBundleName": "JuiceRuntimeSupport",
    "CFBundlePackageType": "FMWK", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
    "MinimumOSVersion": "14.0", "CFBundleSupportedPlatforms": ["iPhoneOS"],
    "UIDeviceFamily": [1, 2], "JuiceRuntimeABI": 1}))
PY
echo "JUICE_EMBEDDED_SUPPORT_LINKED path=$OUT/JuiceRuntimeSupport abi=1"
