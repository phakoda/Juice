# Runtime integration decisions — September 6, 2026

## Canonical implementation

PR #6 is the separately reviewed desktop/presentation layer. Its actual Metal
pixel tests, portable input/geometry tests, source checks, compatibility tests and
iPhoneOS app/helper builds were replayed locally before integration.

PR #7 is the canonical graphics/API/FEX/JIT implementation. PR #8 is superseded
by this consolidated implementation rather than merged as a second competing
patch stack. The original branches retain provenance; no force push or source
branch deletion is necessary.

Retained from #7: the 194-entry runtime manifest and 96-module audited API
catalog, three-architecture PE build matrix, bounded GDI and Metal geometry,
in-place SDR format conversion and padding clearing, per-frame autorelease pools,
16-byte packing only in already-authorized dual mappings, page-isolated ordinary
W^X publication, rollover replanning, bounded atomic retired-range snapshots,
negative-offset overflow fix, and the independently gated JIT state machine.

Adapted from #8: the constant-memory exact-line acknowledgement parser and its
split-boundary/foreground regressions; a 256 MiB aggregate Metal readback budget
including replacement overlap; explicit retained-drawable teardown; and serialized
resize/detach/present handling. There is one graphics policy and one FEX policy,
not two divergent implementations or tests of an unused alternative.

The #8 graphics-only queue filter is intentionally not copied. The Khronos
Vulkan WSI specification's "Querying for WSI Support / Metal Platform" section
requires presentation support for every valid Metal queue family. The canonical
query checks device/function availability, bounded family counts and the actual
family's queue count without incorrectly requiring `VK_QUEUE_GRAPHICS_BIT`.
Reference: https://docs.vulkan.org/spec/latest/chapters/VK_KHR_surface/wsi.html

The two unmerged StikDebug follow-ups are accounted for: foreground readiness and
the macOS compiler probe are already present in #7; background-budget denial now
takes the normal owned failure/cleanup path before opening the external debugger.

## Build failures addressed

The previous #7 failures happened during patch replay, before compilation: its
ABI overlay described nonexistent two-argument exports. The corrected overlay
matches the actual private Win64 three-argument declarations, preserves both
output/alias pointers, and uses a pointer-sized size argument. A regression now
replays every actual optional prefix and deliberately rejects a corrupted ABI.

The competing #8 Wine/FEX overlays are not applied on top of #7. Their initial
jobs also failed during patch preparation. Useful behavior is integrated into
the canonical graphics source and audit patch instead of weakening verification
or retaining an unreplayable second stack.

Once patch replay was repaired, the real D3DX build exposed an omitted external
host generator: `tools/make_xftmpl`, needed by `include/rmxftmpl.h`. Both host-tool
build paths now compile it, Linux verifies its executable architecture along
with the other generators, and native/PE validation explicitly generates the
template header before compiling the platform objects or complete DLL catalog.

The next complete build exposed an architecture-audit error rather than a
compiler error: the checker expected the ARM64EC object identifier `0xA641` in
linked DLL headers. Microsoft documents that linked ARM64EC images use AMD64
`0x8664` plus hybrid metadata. The auditor now verifies that metadata with bounded
PE32+ section, load-configuration and RVA checks; it does not accept plain x64
as a substitute. Regressions cover both metadata versions, ordinary-x64/object
rejection, malformed sizes/pointers/maps, ambiguous sections and all 1,024 byte
truncations of a structural fixture. The corrected parser also accepted the
actual previously built FEX ARM64EC DLL, whose machine field is `0x8664` and
metadata version is 1. No compiled fixture is added to the runtime or source tree.
Reference: https://learn.microsoft.com/en-us/windows/arm/arm64ec

## Validation boundary

Every current-head check must complete before merging the runtime layer: source
and complete patch replay, portable sanitizer suites, actual iPhoneOS app/helpers
and Wine objects, both FEX translators, and all three graphics/API PE builds.
The pull request records exact final commit and workflow results. Historical
green checks on an older implementation are not substituted for current results.

These are source/build integration gates, not physical-device release evidence.
A full linked/signed runtime package, attended iPhone/iPad JIT/TXM and graphics
workloads, and sustained thermals/performance remain explicitly unverified here.
No universal compatibility, measured speedup, HDR output, OpenGL backend,
zero-copy presentation or new platform authorization is claimed.
