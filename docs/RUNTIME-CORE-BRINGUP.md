# Wine graphics, FEX cache, and authorized JIT bring-up

This change extends the standard runtime module manifest and changes production
Wine/FEX/JIT paths. It does not establish desktop-Wine parity or a measured
performance gain. Rebuild the runtimes; a new UIKit binary with old prebuilt
Grape/FEX binaries does not contain these engine changes.

## Graphics/API selection

The shared manifest now selects 14 additional Wine DLLs: `d3d8`, `d3d9`,
`d3d10`, `ddraw`, `d3dcompiler_39`, `d3dcompiler_43`, `d3dx9_43`,
`d3dx10_43`, `d3dx11_43`, `d3dxof`, `gdiplus`, `mlang`, `propsys`, and
`windowscodecs`. The existing native, ARM64EC and WoW64 builders/stagers consume
this manifest. Custom manifest overrides and reused binary packages need
separate checks.

These are the implementations already present in the bundled Wine source, not
newly reimplemented Direct3D entry points. The additional compiler versions and
explicit/delay imports are intentional. `d3dcompiler` is an import-library alias
for the already-selected `d3dcompiler_47.dll`; it is not a missing filename.
`dxguid` and `uuid` are static libraries, not runtime DLLs.

`python3 scripts/juice_graphics_manifest.py` checks the selected outputs and
declared dependencies against 17 pinned in-tree Makefile definitions. Source
changes require reviewing and refreshing the fixture. This check deliberately
does not claim to resolve arbitrary `LoadLibrary` calls, forwards, API sets, or
all dependencies of the pre-existing manifest. JPEG/PNG/TIFF PE-library build
variables are reported separately; selecting Windows Codecs does not prove those
optional libraries were built. Test COM registration with a fresh prefix and
with a backed-up existing prefix updated by Wine's normal `wineboot -u` workflow.

## Metal/Vulkan bridge

The Wine iOS driver now validates queue-family availability instead of returning
presentation support for every index. It rejects missing dispatch, impossible
counts, allocation failure, truncated enumeration, zero-queue families, and
families without graphics capability. This is a conservative driver query, not
Vulkan conformance certification.

Readback layout arithmetic is checked before allocation. Limits match the host
transport's geometry ceiling: 8192 per dimension, 4096 x 4096 pixels, 128 MiB per
allocation, and a 256 MiB process-wide logical readback budget. Replacement
allocations count alongside the old allocation until replacement succeeds.
Failure preserves the previous buffer. Per-surface presentation/update/detach
serialization protects the reusable buffer and metadata; teardown explicitly
breaks the retained drawable link.

Supported bit layouts include BGRA8, RGBA8, RGB10A2 and BGR10A2. The 10-bit
channels are rounded to eight bits and alpha to eight bits. RGBA and packed
10-bit layouts convert in place, including padded and unaligned test inputs.
Native BGRA keeps its padded-row fast path and does not gain an extra full-frame
CPU compaction. This is bit-format conversion, **not HDR tone mapping or
wide-gamut color management**. FP16, XR, multisample and non-2D textures are not
silently treated as four-byte BGRA pixels.

The bridge still performs synchronous GPU readback. It does not add zero-copy
presentation, prove MoltenVK cross-queue/acquisition ordering, implement an
OpenGL driver, or fill missing Vulkan/Direct3D shader or extension semantics.

## FEX translation cache

The production FEX runtime-core overlay uses checked code-placement arithmetic. After cache
rollover it reads the replacement buffer and its new cursor again. It does not
reuse the pre-rollover offset. Both protection boundaries must fit the usable
buffer, excluding its guard page. Overflow, an oversized block, or a failed
protection transition fail before padding is emitted into the destination.
Dispatcher RX-publication errors are checked instead of ignored.

Retired code ranges use a versioned, bounded, lock-free snapshot. Bounds and the
version use sequentially consistent atomics so readers cannot combine one
publication's start with another publication's end. Writers do not spin on an
interrupted writer; a contended slot is skipped. The history remains advisory:
it does not retain old code indefinitely or prove the lifetime of arbitrary
addresses. Placement is arithmetic, not an executable-memory permission grant.

TSO ordering, disabled in-place code linking, CPU-feature detection, guest ISA
semantics, existing W^X rules and signing/entitlement policy remain unchanged.
There is no `-march=native` assumption about the Linux build host and no attempt
to force every processor core busy. The testable improvements are cache-space
correctness and avoiding unnecessary work, not an invented FPS claim.

The runtime-core FEX changes are a final overlay after the existing base, StikDebug JIT,
lifecycle, and validation layers. Preserve local changes when upgrading an existing
managed checkout; the overlay can be checked/applied without rewriting the base patch,
then `make verify-fex` can validate the complete stack. Alternatively, preserve
all old source/build directories and use fresh paths for this build:

```sh
export JUICE_FEX_SOURCE="$PWD/build/fex-runtime-core-source"
export JUICE_FEX_BUILD="$PWD/build/fex-runtime-core-arm64ec"
export JUICE_FEX_WOW64_BUILD="$PWD/build/fex-runtime-core-wow64"
make
```

The assembler honors the two FEX build-directory variables; do not mix newly
compiled helpers with translators taken from an old directory.

## JIT authorization and handoff

Readiness requires all of: the still-owned launch identity, accepted handoff,
OS-backed debugger observation, a complete launch-specific runtime marker, and
foreground activity. The existing coordinator supplies the actual OS check and
PID/generation ownership; a log marker alone does not grant permission. The
OS remains the authority for whether executable memory may be used.

The exact marker parser is a fixed-size streaming matcher. It survives every
chunk boundary and unrelated preceding/following log lines. It accepts LF or
CRLF but rejects prefixes, suffixes, NUL contamination, wrong identities and
unterminated lines. An arbitrarily long bad line consumes constant parser
storage. Existing deadline, cancellation, stale-child and single-resume rules
remain authoritative. This changes coordination, not JIT entitlement eligibility
or platform security policy, and introduces no signing bypass.

## Validation gates

Run `bash scripts/test-runtime-core-host.sh` with a native C11/C++20 compiler.
The normal mode reads the actual FEX runtime-core overlay and in-tree Wine
Makefiles. `JUICE_RUNTIME_CORE_FIXTURE=1` is an explicit source-subset mode: it
uses captured original hunks and Makefile definitions and cannot certify the
complete Wine/FEX source trees. CI explicitly disables that mode.

The portable suite includes the production transition and framing logic,
checked pixel/geometry helpers, a query function extracted from `vulkan.m`, and
the production FEX placement fragment extracted from the runtime-core overlay. The latter two
use mocked platform services; neither is a graphics-driver or ARM64EC build.
The fixture includes only the reviewed FEX hunks, with offsets normalized where
unrelated hunks are absent. It is never substituted for the complete FEX patch.

Required before release: existing source checks; complete Wine/FEX patch-stack
verification; native iPhoneOS app/helper compilation; actual Wine iOS driver
objects; complete ARM64EC and WoW64 translator builds; full native/hybrid/i386 PE
module builds and packaging; then attended device acceptance. The workflows
now trigger the existing FEX matrix and Wine object compile on relevant PRs;
the Wine compile includes the actual `vulkan.m` and `iosdrv.c` objects. Object
compilation is not a linked distributable runtime.

Device acceptance must cover native/x64/x86 launch, independent DLL loads and
COM activation, D3D8/9/10 and D3DX workloads, image codecs actually included in
the build, resize and multi-window rendering, supported/unsupported swapchain
formats, reconnect, background/foreground JIT handoff, cancellation and timeout,
and sustained code-cache churn with multiple translated threads. Compare cold,
warm and sustained runs on the same device/configuration using the existing
runtime evidence tool. Retain binary hashes, failures and thermal data; never
turn an unrun workload into a passing compatibility claim.
