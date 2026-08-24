# iOS host force-quit recovery v10

This directory records the scoped device checks for the v10 UIKit host fix.

- `trollstore-install.log` proves a clean TrollStore/CoreTrust installation of
  `Juice-Compatibility-ForceQuit-XRGB-v10-20260823.tipa` returned success.
- `wineserver-recovery.log` proves that a replacement launch can stop a stale
  ARM64-prefix wineserver and that the old process exits.
- `source-verify.log` records the repository verification run for the exact
  source used by the package.
- `SHA256SUMS` binds those records to the local TIPA.

The on-screen force-quit/reopen check and corrected XRGB desktop screenshot are
recorded separately after the iPad is unlocked. This directory does not claim
that those two interactive checks have passed yet.
