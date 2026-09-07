# SideStore embedded runtime

This is a different runtime architecture, not the privileged TrollStore package
renamed to `.ipa`. The app requests only `get-task-allow`; SideStore supplies the
development provisioning identifiers when signing. Distribution certificates
that do not authorize debugging cannot make the app attachable in StikDebug.

## Build and installation

Use the **SideStore embedded IPA** Actions workflow or run `make sidestore` on
a prepared Linux build host. The outputs are
`dist/Juice-SideStore-<revision>.ipa`, its SHA-256 file, and a structural audit.
The historical **Build Juice IPA** workflow is the legacy, privileged Wine
loader target and is not a substitute for this package.

Install the SideStore IPA using development signing. Configure StikDebug's
pairing file, developer disk image and local VPN separately. Open Juice, press
**Enable JIT with StikDebug**, allow the switch to StikDebug, and return to Juice.
The handoff uses `NSBundle.mainBundle.bundleIdentifier` after signing and
`getpid()`, never a hard-coded identifier or a helper PID. The log reports the
effective `get-task-allow` entitlement, identifier, PID and session generation.

On TXM systems the allocator speaks the `universal.js` protocol:
`x16=1; brk #0xf00d` prepares executable memory; `x16=0; brk #0xf00d`
detaches. Opening a URL is not authorization. The host verifies debugger
authorization, separate writable/executable mappings, and actual generated-code
execution before declaring JIT ready. If TXM detection is unavailable, the user
chooses a protocol explicitly. Missing detection is not proof of absent TXM.

## Runtime boundary

```text
Juice.app — one development-signed iOS application process
  UIKit main thread
  StikDebug coordinator -> external StikDebug application
  JuiceRuntimeSupport.framework
    private Wine environment and standard streams
    per-thread working directories
    tracked guest threads and guest-scoped signal dispatch
    checked memory ownership and prepared executable arena
  JuiceWineServer.framework — server worker, private socketpair
  JuiceNTDLL.framework      — guest worker, embedded Wine entry
  additional Wine Unix libraries and dependencies — signed frameworks
  Grape / Grape-X64         — PE modules, registry template and NLS data
```

There is no `posix_spawn` of `wine`, `wineserver`, `grape-trace-parent`, or
`grape-nested-wrapper`. The server adopts a private socketpair. It does not
daemonize, listen for unrelated clients, install process-wide server signals,
or use ptrace against its host. Server signals target only tracked guest
threads. Guest termination must not terminate the UIKit application process.

Wine's POSIX substitutions are component-local compile-time mappings; they do
not interpose libc for UIKit. Native Wine code is packaged as actual `MH_DYLIB`
frameworks with rewritten dependency paths and without private entitlements.

Wine does not reserve or release the host's `__PAGEZERO`. Fixed replacements
must lie inside already-owned mappings. Native PE code is relocated while
non-executable, then published through prepared RX aliases. Builtin PE sections
are aligned to 16-KiB pages so code and writable data need not share a host
page. Writable/executable allocations are not silently accepted as RWX.
Published code is bounded and quarantined until the host application exits.

## Compatibility limits

This backend hosts **one 64-bit Windows process per Juice process**. Native
ARM64 and translated x86-64 are the intended formats. `NtCreateUserProcess`
returns `STATUS_NOT_SUPPORTED`; applications requiring helper executables,
COM services, installers, Wineboot or process trees are not advertised as
working. The prefix is explicitly preseeded, not marked successfully
initialized by a fabricated Wineboot acknowledgement.

32-bit x86 is rejected before launch. It requires a separate low-address-space
design; this target never invokes the legacy kernel/low-VA helpers. After a
session exits, close and reopen Juice before starting another. Wine globals and
guest images are not safely unloadable and reinitializable in this backend.

The executable arena has a 384-MiB virtual budget. The FEX pool is limited to
256 MiB, with PE publication sharing the remaining capacity. These are resource
limits, not performance measurements or claims about physical-memory use.

## Validation and release gates

The build checks patch replay, address-interval arithmetic, real iPhoneOS
host/framework linking, native ABI exports, absent child-process imports,
framework dependency closure, PE page alignment, minimal entitlements, and ZIP
checksums. Package audits record `device_execution_verified: false` because
static checks do not prove device execution.

Physical acceptance requires an attended SideStore install, Juice appearing in
StikDebug, successful authorization and executable-memory probes, a rendered
single-process Wine application, input, normal guest exit, and a responsive
UIKit host. Native ARM64 and translated x86-64 need separate execution tests.
Do not infer arbitrary Windows compatibility, x86-32 support, repeat-session
support or a working process tree from a successful CI artifact.

Protocol reference: `StikDebug/StikJIT/INTEGRATION.md` and
`StikDebug/StikDebug/StikDebug/Scripts/universal.js`. SideStore setup reference:
`docs.sidestore.io/docs/advanced/jit`. Compatibility depends on the actual
installed StikDebug and iOS versions.
