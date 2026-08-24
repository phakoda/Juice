# Installable builds

`Juice-v0.2.0-rc2.tipa` is the current release candidate. It contains native
ARM64, experimental x86-64 FEX and i386 WoW64/FEX, bundled GnuTLS and CA trust,
the verified Chocolate Doom path, and the latest translated-address-space and
prefix-lifecycle fixes. SteamSetup installs and downloads its full client
payload, but full Steam startup and OfficeSetup are not yet verified.

`Juice-Steam-Chocolate-Network-v0.2.0-rc1.tipa` is retained as the preceding
release candidate.

`Juice-Steam-Chocolate-Network-20260822.tipa` is retained as the preceding
milestone artifact, but is superseded by `v0.2.0-rc1` because its Linux reuse
build could skip nested Mach-O signing.

The TIPA is stored with Git LFS. Verify it before installation:

```sh
sha256sum -c Juice-v0.2.0-rc2.tipa.sha256
```
