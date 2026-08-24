# Steam client x86-64 compatibility result (iPad, 2026-08-24)

Status: **partial, not a passing Steam-client launch**.

- SteamSetup completed and the updater downloaded the complete 336,229 KiB client payload over HTTPS.
- The iOS low-address-space fixes removed the earlier private-Wine-map fault loop and allowed the updater to reach installation.
- Installation currently stops when Wine cannot provide one contiguous 32-bit guest allocation: `base 0x0 size 09800000` (152 MiB), at line 10452 of `Juice-steam-v49-install-debug.log`.
- The updater then exits; no claim is made that the Steam client UI launches successfully.

This evidence is retained to make the remaining compatibility boundary reproducible and to prevent regression of the successful installer, TLS, and download stages.

## SHA-256

```
7a2c7722f844391fcb67ead383a0a799c0c66b909cdef38ce133bdac9ce68c27  Juice-steam-v46-high-private-mmaps.log
5b69f3617e09f1d4a09ff5e80c63b2ac916a33f4bea5e707bc2668cf94d86efc  Juice-steam-v48-full-win32-register.log
849ff7db82dec49003a7137a2b2ea60f770ca6c58ac86292d5dc1010e7191ba5  Juice-steam-v49-install-debug.log
```
