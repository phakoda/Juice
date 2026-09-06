# Runtime hardening: validation and remaining compatibility gates

This integration is a reliability improvement, not a claim of macOS Wine parity.
An iPhoneOS app compile does not build or execute the complete Wine/FEX runtime.
Historical device proofs in the repository are not new validation of this change.

## Reproducible automated gates

Run from the repository root:

```sh
make verify
bash scripts/verify-mainline-hardening.sh
python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
bash scripts/test-host-transport.sh
bash scripts/test-runtime-io-host.sh
```

On macOS with Xcode, also run:

```sh
make app
make launchers
bash scripts/test-zip-extractor-host.sh
```

`test-host-transport.sh` runs the production socket I/O and UTF-16 chunk helper
under AddressSanitizer and UndefinedBehaviorSanitizer. The companion `test-runtime-io-host.sh` tests sockets, pipes and the shared
Foundation writer. On macOS the host tests additionally exercise the framebuffer and
persistent-log implementation. It does not substitute mocks for an iOS device,
Wine, Metal, or FEX. Its timeouts are hang guards, not performance benchmarks.
The patch-stack tests verify that successful, repeated and failed checks leave
the source tree unchanged and detect drift outside incremental-patch hunks.

## Behavioral changes and limits

The host enqueues complete input packets instead of performing blocking socket
writes on UIKit's thread. Each connection owns a CLOEXEC duplicate, a FIFO limited
to 2 MiB / 512 pending messages, an 8 MiB process-wide queued-byte budget,
and a two-second enqueue-to-write deadline.
Timeout, overflow or a partial failed write shuts down that connection rather
than continuing a corrupt stream or silently dropping a key-up. A successful
send return means **queued**, not acknowledged by a Windows program. These
latency and capacity defaults still need slow-application device testing.

Software framebuffers retain their coalescer identity but take ownership of new
full-frame storage, removing one redundant full-frame copy. Dirty updates and
window destruction must match the current connection owner. Aggregate incoming
frame reservations are limited to 128 MiB; retained baselines are limited to
256 MiB and 128 windows. Exceeding a budget disconnects the producer and emits a
`DISPLAY_BUDGET_EXCEEDED` diagnostic. These are baseline/in-flight limits, not a
claim that all UIKit images, GPU allocations, Wine and FEX fit in that amount.

Large text pastes preserve UTF-16 surrogate pairs. Persistent logs rotate before
exceeding either 8 MiB segment, including large and concurrent appends; export
reads at most the captured tail of the opened inode. Launch generation checks
and normal child reaping share one main-queue turn. After Stop, the termination
worker owns both the delayed process-group kill and the final blocking reap.

## Physical-device acceptance matrix

Record a result for each packaged architecture: native Windows ARM64, translated
x64, and i386/WoW64 where included. Keep the app/runtime commit, device model,
iOS build, signing/install mode, graphics backend, program version/hash, prefix
state and logs with every result. A missing result is **not tested**, not passed.

| Area | Required observations |
| --- | --- |
| Startup and shutdown | Cold/warm prefix launch, failed executable, immediate Stop, rapid Stop/relaunch, child process and wineserver cleanup. |
| Input and windows | Multi-window focus, modal dialogs, large Unicode paste, key-up during reconnect, physical mouse/HID/gamepad, touchscreen and resizing. |
| Installation and files | Portable ZIP dependencies, MSI/BAT/CMD/REG, spaces and non-ASCII paths, file picker cancellation and repeated imports. |
| Graphics | GDI repaint/dirty regions plus each shipped Vulkan/Metal/MoltenVK or other graphics path; do not infer Direct3D/OpenGL support from a Vulkan host build. |
| Audio and networking | Playback/capture supported by the selected build, DNS/TLS/downloads, reconnect and foreground transitions. |
| Soak and memory | Multiple applications, minimized/hidden windows, reconnect storms, memory warnings, log rotation and export under continuous output. |
| Translation/JIT | x64 and WoW64 children, executable-memory exhaustion, cache invalidation and supported launch modes on the actual target OS. |

Use the existing `arm64-smoke-build`, `input-smoke-build`, `network-smokes`,
`graphics-smokes`, and architecture-specific device smoke targets as starting
points; successful compilation alone is not a runtime result. The complete Linux
build remains `make`, as described in README.md.

For performance comparisons, keep the same hardware, OS, workload, resolution,
runtime/backend configuration and power/thermal conditions. Measure cold and
warm startup separately, then steady-state frame-time median/p95/p99, input
latency, resident memory and thermal behavior. Compare repeated runs against the
previous main build and preserve raw measurements. Removing a copy or adding
coalescing is not, by itself, evidence of an FPS improvement.

## Separate JIT work

The StikDebug PR is deliberately not treated as validated by these host tests.
Its coordinator targets `grape-trace-parent`, but that helper spawns Wine as a
separate process. Correct child ownership, cancellation, debugger readiness,
allocator lifetime, repeatable patch application, and physical-device execution
must be established before enabling that path. Existing supported launch modes
must not acquire a mandatory dependency on an unrelated debugger application.
