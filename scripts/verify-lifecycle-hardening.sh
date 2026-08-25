#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

required=(
  app/JuicePrefixRepair.m
  app/JuiceMemoryPressure.m
  app/JuiceControlLaunchRouting.m
  app/JuiceCompatibilityLabels.m
)
for path in "${required[@]}"; do
  test -f "$ROOT/$path" || { echo "Missing lifecycle-hardening source: $path" >&2; exit 2; }
  grep -Fq "app/$(basename "$path")" "$ROOT/scripts/build-app.sh" || {
    echo "build-app.sh does not compile $path" >&2
    exit 3
  }
done

# Prefix health checks must follow the same jailbreak-vs-sandbox root selection
# as the storage layer, before prefixNeedsInitialization is computed.
grep -Fq 'access(legacy.fileSystemRepresentation, W_OK)' "$ROOT/app/JuicePrefixRepair.m"
grep -Fq 'NSSearchPathForDirectoriesInDomains(NSDocumentDirectory' "$ROOT/app/JuicePrefixRepair.m"
grep -Fq 'constructor(250)' "$ROOT/app/JuicePrefixRepair.m"
grep -Fq 'storage_root=' "$ROOT/app/JuicePrefixRepair.m"

# Hidden UIKit snapshots can be discarded under pressure because the validated
# mutable per-HWND baseline remains in JuiceRuntimeHardening.
grep -Fq 'didReceiveMemoryWarning' "$ROOT/app/JuiceMemoryPressure.m"
grep -Fq 'hidden_images_trimmed=' "$ROOT/app/JuiceMemoryPressure.m"
grep -Fq 'visible' "$ROOT/app/JuiceMemoryPressure.m"
grep -Fq 'lastLegacyImage' "$ROOT/app/JuiceMemoryPressure.m"

# Windows-side launch requests must not impose their own x64-only policy. They
# populate the regular launcher and let JuiceArchitectureRouting decide.
grep -Fq 'JUICE_CONTROL_ACTION_LAUNCH_PATH' "$ROOT/app/JuiceControlLaunchRouting.m"
grep -Fq 'architecture=auto' "$ROOT/app/JuiceControlLaunchRouting.m"
grep -Fq 'launchRequested' "$ROOT/app/JuiceControlLaunchRouting.m"
if grep -Fq 'experimentalX64' "$ROOT/app/JuiceControlLaunchRouting.m"; then
  echo "Control launch routing must not duplicate FEX policy." >&2
  exit 4
fi

# User-facing terminology should match unified i386/x86-64 translation support.
grep -Fq 'x86 / x86-64 FEX translation' "$ROOT/app/JuiceCompatibilityLabels.m"
grep -Fq 'constructor(325)' "$ROOT/app/JuiceCompatibilityLabels.m"

echo "JUICE_LIFECYCLE_HARDENING_VERIFY_OK"
