# Graphics, API, FEX and JIT bring-up

This layer extends the Wine iOS driver, packages additional Wine builtin API
families, improves FEX code-cache publication, and strengthens launch-owned JIT
readiness. It does not claim complete Linux/macOS Wine compatibility or measured
performance on an iPhone/iPad. Compilation, source inspection, portable behavior,
and physical-device execution are separate acceptance gates.

## Runtime API coverage

`config/runtime-modules.txt` adds 84 Wine builtin DLL targets to the previous
110-target manifest (194 total). The 96-name `config/graphics-api-modules.txt` catalog includes
those additions plus the existing modern graphics backends they depend on.

The added families are DirectDraw and Direct3D 8/9/10 entry points; D3DRM/D3DXOF;
D3DX9 versions 24–43, D3DX10 versions 33–43, and D3DX11 versions 42–43; the
shader-compiler versions actually present in the pinned Wine tree; composition
entry points; GDI+, Windows Imaging Component, text/color/property helpers; and
Wine C/C++ runtimes including modern atomic-wait and locale-identifier helpers.
The missing literal imports `xmllite` for Direct2D and `mlang` for GDI+ are also
included. These are built from the repository's Wine sources, not downloaded
Microsoft binaries. Wine does not provide d3dcompiler_44 or d3dcompiler_45 in this
pinned tree; the catalog deliberately does not invent replacements.

`scripts/verify_graphics_api.py` checks source module identities, manifest names,
case collisions, and literal normal/delayed imports. It reports configured import
expressions and declared stub exports rather than hiding them. It never evaluates
Make expressions or shell commands. Optional build inspection validates each DLL's
PE machine and DLL characteristic and records its SHA-256.

This audit is not a complete Windows loader or API conformance test. Dynamic
loads, API-set resolution, configured codec libraries, transitive behavior, COM
registration, and applications' native overrides require additional validation.
In particular, packaging `windowscodecs` does not manufacture PNG/JPEG/TIFF/LCMS
support when those PE dependencies were not configured. Likewise, packaging
`opengl32`, DirectComposition, or D3D12 does not establish a working OpenGL driver,
composition implementation, or a particular Direct3D feature level.

## Graphics-driver changes

The Metal bridge accepts BGRA8 and RGBA8 normalized/sRGB textures plus packed
RGB10A2/BGR10A2 normalized textures, converts their readback to the existing BGRA
transport, and clears row padding. Ten-bit conversion is rounded SDR quantization,
not HDR tone mapping or end-to-end HDR display support. Unsupported formats,
multisampled textures, non-2D textures, and framebuffer-only textures are rejected
before an incompatible blit.

GDI and Metal allocations share checked dimension/stride/size arithmetic: at most
8192 pixels per dimension, 4096 squared pixels, and 128 MiB per payload. Rectangle
subtraction widens before subtraction; GDI rejects inverted rectangles before
passing them to Wine. Allocation failure preserves the previous reusable buffer
or surface instead of destroying it first.

Metal readback buffers are reused where compatible. Each present has an
autorelease pool, and readback allocation, conversion and IPC reuse are serialized
per surface, including resize and detach. A process-wide 256 MiB readback budget
counts old and replacement allocations together, and failed replacements release
only their reservation. Detach and final teardown explicitly clear the retained
drawable. The native BGRA path preserves padded rows without a full-frame copy;
padding is cleared before transport. Queue-family queries validate the actual device's family count and
queue count. VK_EXT_metal_surface guarantees presentation for valid queue families;
this does not justify accepting an out-of-range family index.

The bridge still waits synchronously for its readback command buffer. Removing
that wait alone is incorrect: completing work on the readback queue is not a
producer/render-queue fence. A future asynchronous or zero-copy bridge must add
explicit producer synchronization, bounded in-flight ownership, resize/teardown
fences and device tests before replacing this path. This layer does not claim to
solve that existing cross-queue synchronization boundary.

## FEX translation and code publication

`patches/fex-juice-codegen.patch` applies after the existing iOS, StikDebug,
lifecycle and validation layers at the pinned FEX revision.

For an already-authorized dual-mapped code buffer, translated blocks use their
16-byte ABI alignment rather than consuming a new 16 KiB page for each block.
The non-dual-mapped path retains page-isolated W^X publication. No new authorization
mechanism is introduced, and in-place block linking remains disabled on iOS.
Existing x86 memory-ordering defaults are unchanged.

Publication offsets and bounds are recalculated after a full code cache is
replaced. The shared arithmetic helper checks alignment, overflow, capacity and
guard-page exclusion before copying or protecting generated code. The retired
code-range diagnostic records use a versioned, lock-free, bounded snapshot, so a
fault handler cannot combine the start of one retired generation with another's
end. Readers neither spin nor allocate nor take a lock; an in-progress record is
not accepted as evidence. Negative memory offsets avoid signed-negation overflow.

The packing test fits 128 synthetic 500-byte blocks rather than four in a 64 KiB
region. That is an arithmetic/storage example, not a 32-times speedup benchmark.
Actual cache misses, compilation rate, RSS and sustained throughput must be
measured per workload and device.

## JIT lifecycle and authorization

The state machine now requires three independent observations before readiness:
URL handoff acceptance, observed debugger authorization for the owned child, and
a nonce-matched runtime acknowledgement. It preserves reordered callbacks and
only resumes or transitions to ready while foregrounded. A runtime output marker
alone is not authorization. Cancellation and child-ownership revocation take
precedence over timeout/error actions, and stale callbacks cannot signal a reused
numeric PID. Terminal states ignore repeated callbacks.

The runtime acknowledgement parser consumes arbitrary output chunks in constant
memory. Only an exact PID/nonce marker on a complete LF or CRLF-terminated line
counts; prefixes, suffixes, unterminated and overlong lines do not. An unavailable
iOS background-task budget rejects the handoff through the normal owned cleanup
path rather than leaving an externally suspended child behind.

The coordinator's entitlements, debugger-status probe, per-launch nonce, PID and
generation ownership, continuous-clock deadline and platform permission checks
remain authoritative. There is no signing exploit, entitlement escalation,
device-wide task access, new security bypass, or fallback that treats denied JIT
permission as success. Physical StikDebug/TXM interaction still requires a device.

## Reproduce the source and portable gates

Run from a complete Juice checkout:

```sh
make verify
bash scripts/verify-stikdebug-jit.sh
bash scripts/test-jit-host.sh
bash scripts/test-fex-codegen-host.sh
bash scripts/test-graphics-policy-host.sh
python3 -m unittest discover -s scripts/tests -p test_graphics_api.py -v
python3 scripts/verify_graphics_api.py
```

The graphics policy and FEX policy scripts use AddressSanitizer and
UndefinedBehaviorSanitizer and accept `CC`/`CXX` overrides. The JIT test enumerates
279,936 event sequences in eight lifecycle environments. FEX policy tests include
76,116 publication intervals and concurrent retired-range readers/writers. Color
tests cover all 256 eight-bit and 1024 ten-bit channel values, all four packed
alpha values, row padding, unaligned allocations and 1024 layout widths.
The acknowledgement suite additionally checks 2,985,984 event/foreground
orderings and every marker chunk boundary. The repository patch-stack regression
replays all five actual Wine optional-layer prefixes, validates both three-argument
pointer-sized private Win64 JIT exports, and rejects ABI drift without changing
the source tree. Run it with:

```sh
python3 -m unittest discover -s scripts/tests -p test_patch_stack.py -v
```

The full translator builds are independent of those lightweight policy tests:

```sh
bash scripts/build-fex-arm64ec-linux.sh
bash scripts/build-fex-wow64-linux.sh
```

The graphics/API PE compile matrix uses the pinned compiler and production
resource wrapper, never executes a target binary, and verifies the resulting DLLs:

```sh
bash scripts/test-graphics-api-pe-linux.sh aarch64
bash scripts/test-graphics-api-pe-linux.sh arm64ec
bash scripts/test-graphics-api-pe-linux.sh i386
```

On a Mac with Xcode's iPhoneOS SDK and the repository's build-host dependencies,
`bash scripts/test-wine-graphics-ios-compile.sh` compiles the actual Wine driver,
IPC/control, native JIT, loader and server translation units to ARM64 Mach-O
objects. `make app` and `make launchers` separately compile the UIKit app/helpers.
These checks are not a complete linked/distributable runtime or a signed TIPA.

GitHub Actions preserves compiler logs, per-DLL hashes, and exact source metadata.
Use the PR's checks for results associated with a particular commit; adding a
workflow is not evidence that the workflow passed.

## Patch ordering

The checked-in Wine tree includes `wine-ios.patch`, then
`wine-ios-runtime-hardening.patch`, then `wine-ios-graphics.patch`. The JIT,
lifecycle, handoff and pointer-sized ABI patches remain ordered optional overlays. The full stack
is checked in an isolated copy so a verification run cannot temporarily mutate
an active compiler's inputs. Keep the graphics mirror and checked-in sources in
sync; do not fold later layers into the base patch without updating the stack.

FEX source preparation recognizes and validates the complete applied prefix
before applying remaining layers. This matters because the codegen overlay
changes base-patched lines; reversing just the base is not a valid reuse check.

## Physical acceptance before release

| Area | Required evidence |
| --- | --- |
| Native ARM64 | Existing desktop, text, installers and GDI application regressions still pass. |
| Graphics | Color/channel patterns, resize/minimize/restore, multiple windows, unsupported-format handling and repeated teardown. |
| APIs | Representative DirectDraw/D3D8/9, D3DX/shader compiler, WIC/GDI+ and C++ applications exercise functions, not just LoadLibrary. |
| Translation | x64 and x86 programs survive repeated cache rollover, exceptions and multithreaded execution without changing ordering defaults. |
| JIT | Accepted/rejected handoff, authorization denial, background/foreground ordering, cancellation, timeout, child exit and stale callback cases. |
| Performance | Exact runtime/app hashes; cold/warm/sustained phases; frame time, CPU time, RSS, temperature/thermal state and power-mode context. |

Passing the source/build gates makes this layer reviewable. It does not establish
universal compatibility, measured speedups, kernel-driver/anti-cheat support,
stock-iOS deployability, or correctness on untested hardware.
