# Runtime readiness and review evidence

Review date: 2026-09-05 (America/New_York). CI timestamps below are 2026-09-06 UTC.

## Status and scope

This review improves the existing modified-iOS runtime. It does not establish stock-iOS support, App Store eligibility, Mac Wine parity, a new compatible-application count, or measured device performance. The UIKit host and launcher helpers compile for iPhoneOS; portable I/O, native Foundation writer/reaper tests, and ZIP regressions pass. No physical iPhone/iPad was available in this review, and the full Wine/FEX runtime was not rebuilt or exercised.

The starting main commit was `c0de19d93064eac25f87524849e12bb2d49e9a4f`. PR #2 preserves its graphics/client-surface, Vulkan/Metal, GameController, raw-HID and translated-runtime paths. Source invariants protect their presence; those checks are not proof of runtime correctness.

## Pull request decisions

| PR | Decision | Reason |
| --- | --- | --- |
| #1, old runtime hardening | Leave closed; do not merge the obsolete branch | It was already closed before this review. #2 is its current-main replacement and avoids reverting newer mainline work. |
| #2, current-main hardening | Retain and integrate the reviewed, tested changes | Includes the existing transport/input/import work plus the fixes and behavioral tests below. |
| #3, StikDebug JIT | Keep as an experimental draft, separate from main | Useful rather than obsolete, but foreground handoff, child ownership and full runtime/device validation remain merge blockers. |

No source branch was force-pushed or deleted. Keeping the old branch history preserves provenance without integrating an obsolete implementation.

## Changes added during this review

### Ordered, bounded host input

`JuiceAsyncWriter` owns a close-on-exec duplicate of its connection, rather than allowing queued work to reuse a borrowed numeric descriptor. Display input, CLI stdin and control replies use ordered worker queues instead of blocking UIKit writes. Queue admission is bounded by bytes and packet count: a global 8 MiB budget, at most 512 queued packets per writer, a 2 MiB display queue, and a 128 KiB CLI queue. CLI lines are limited to 64 KiB of UTF-8 input; rejected input stays in the field.

`JuiceWriteWithDeadline` uses a monotonic deadline, nonblocking descriptors, short polling slices and cancellation. EINTR retries do not reset the deadline. Socket and pipe stalls have a two-second per-packet write deadline in the asynchronous writer. This is not an end-to-end queue-latency guarantee. A partially written socket packet is followed by connection shutdown, not by another packet appended to a corrupted stream. Queue overflow on display input also disconnects rather than silently losing a key/button release.

A macOS behavioral test exposed an important portability difference: relying on `MSG_DONTWAIT` alone did not bound the Darwin write. The corrected implementation explicitly sets `O_NONBLOCK` on sockets as well as pipes. Since a duplicated descriptor shares file status flags, the display reader now handles normal EAGAIN with polling rather than interpreting it as a disconnect.

Launch Stop cancels CLI writers; display teardown removes and cancels the connection writer before releasing its borrowed descriptor. Control-request header reads have an idle timeout. This timeout does not cover an interactive document-picker round trip.

### Frame delivery

Full-frame baseline refreshes transfer ownership of the reader's buffer instead of performing an additional full-frame memcpy. Dirty rectangles must match the baseline's connection and peer identity. Invalidation releases baseline storage. These supplement PR #2's dirty-rectangle transport and coalescing; they are not a new zero-copy or Metal renderer, and no FPS improvement is claimed without a device benchmark.

### Child process ownership

The old output-reader path checked launch generation on the main queue, then reaped on a worker. Stop could run between that check and the reap, scheduling a delayed signal after the leader PID became reusable.

`JuicePollCurrentChild` now performs the ownership check, `waitpid(WNOHANG)` and completion/state update in one serialized owner-queue turn. A stale owner leaves the child to the termination path. The queue never blocks waiting for the process to exit. This fixes the identified reap race; it is not a complete redesign of all launch or shutdown work.

### Experimental JIT branch

On #3, real iPhoneOS compilation exposed unavailable `posix_spawnattr_*sched*` APIs. The branch now copies supported, requested spawn attributes and propagates errors. The StikDebug backend is off by default and requires `JUICE_ENABLE_STIKDEBUG_JIT=1` in the child environment; `JUICE_DISABLE_STIKDEBUG_JIT=1` takes precedence. This is a developer gate, not a user-facing backend selector or validated working handoff.

The review on #3 records these remaining blockers:

- `applicationWillResignActive:` currently stops all Wine processes, conflicting with opening StikDebug while preserving a suspended target. A narrowly scoped, bounded and cancellable handoff state must integrate with Stop, replacement and foreground/background transitions.
- Delayed JIT callbacks hold a raw PID without launch ownership or a process-identity fence. They must not signal a new process after the old child exits or is reaped. Checking `CS_DEBUGGED` alone does not establish the expected script or target identity.
- A spawn that succeeded must retain one explicit cleanup/reaping owner even when subsequent handoff setup fails.
- The Wine/FEX patch stack, executable-memory transitions and detach/handoff behavior still need full build and physical-device evidence.

## Reproducible checks

From a full checkout:

```sh
make verify
bash scripts/verify-mainline-hardening.sh
bash scripts/test-runtime-io-host.sh
```

On macOS with the iPhoneOS SDK:

```sh
make app
make launchers
bash scripts/test-runtime-io-host.sh
bash scripts/test-zip-extractor-host.sh
```

The I/O test script enables AddressSanitizer and UndefinedBehaviorSanitizer by default and treats compiler warnings as errors. Linux runs the portable C cases and explicitly skips Foundation-only tests. macOS runs all three suites. Native test processes have watchdogs; CI jobs have explicit time limits.

| Test suite | Behavioral coverage | Result at reviewed commit |
| --- | --- | --- |
| Portable I/O, 5 cases | Ordered large writes, socket/pipe deadlines, cancellation, EINTR, closed peers and blocking-descriptor rejection | Pass on Linux and macOS |
| Foundation writer, 4 cases | Mutable-buffer snapshots and ordering, descriptor reuse, queue bounds/pipes, partial-write timeout and stream abandonment | Pass on macOS |
| Child reaper, 2 cases | Normal completion and deterministic ownership revocation before child exit | Pass on macOS |
| ZIP regressions | Valid/large/legacy-name archives and rejection of unsafe paths, collisions, CRC/header mismatches and invalid directory data | Pass on macOS |
| iPhoneOS build | UIKit app and launcher helpers | Pass; existing document-picker deprecation warnings remain |

Evidence for `459f29c6bcc6a5dac0680dd572cdbd020af4ed7d`:

- Source checks run: https://github.com/phakoda/Juice/actions/runs/34007377035
- iPhoneOS/macOS job: https://github.com/phakoda/Juice/actions/runs/34007377035/job/101416970823
- Successful markers: `JUICE_IO_TESTS_OK cases=5`, `JUICE_ASYNC_WRITER_TESTS_OK cases=4`, `JUICE_CHILD_REAPER_TESTS_OK cases=2`, `JUICE_ZIP_HOST_TESTS_OK`.
- Source archive SHA-256: `88c350ab69e08b03b1f0651c25db045320923a5bdfec784549cbde6ce4caac2b`. The downloaded archive matched the reviewed local source files; the only expected workflow difference was the temporary cancellation job.
- #3 host-build fix `fe9ac9074b17cfd053ab83870baab699fbbf9250`: https://github.com/phakoda/Juice/actions/runs/34006875694

The temporary review archive workflow and one-off stalled-run cancellation job are removed after capturing this evidence. Functional regression checks remain in Source checks.

## Release gates toward broad Windows compatibility

These are proposed acceptance gates, not completed tests. A green host build is insufficient to mark them done.

| Gate | Required evidence |
| --- | --- |
| Complete runtime/package | Rebuild the intended ARM64, x64 and x86/WoW64 runtime variants, audit packaged dependencies, record source/runtime/package hashes, install on a supported modified-iOS device, and perform a clean-prefix boot. The full Linux build entry point is `make linux-x86_64-x64`; it was not run in this review. |
| Executable coverage | Test exact versions and architectures of simple GUI/CLI apps, MSI installation, portable ZIP apps, .NET-dependent apps and selected real productivity/game workloads. Record launch, usable UI, file open/save, clean exit, and failure logs separately. |
| Graphics | Exercise software/GDI, each advertised Direct3D/Vulkan translation path, resize, dialogs, multiple windows, surface destruction/reconnect and foreground recovery. Existing entry points include `scripts/run-graphics-smoke-device.sh` and `scripts/run-input-smoke-device.sh`. |
| Integration | Test raw and text keyboards, large paste, mouse buttons/wheels, controller reconnect, file import/export, audio, networking/TLS, installers and repeated launch/Stop sequences. Existing network smoke entry point: `scripts/run-network-smoke-device.sh`. |
| Device lifecycle | Test app switching, interruption, document pickers, lock/unlock, background/foreground, memory pressure, runtime crash and stale callbacks on each supported installation/OS class. Treat #3's handoff as a separate gate. |
| Sustained performance | Compare identical program versions, data and render resolutions against the previous Juice build and a clearly identified Mac Wine baseline. Record cold/warm launch, median and p95 frame time, input latency, peak/resident memory, dropped/coalesced frames, thermal state and failures during a sustained workload. Do not infer device FPS from host socket throughput. |

Compatibility results should identify device model, OS version, installation method, Juice commit, runtime hashes, executable version/architecture, resolution and test steps. Unsupported and untested are distinct outcomes. Broad parity should be defined by a passing workload matrix, not by the presence of a feature flag or a successful source grep.
