# Launch-owned StikDebug integration

This backend remains experimental and opt-in. It is not stock-iOS support or
proof that a particular StikDebug/TXM version works. Do not remove the gate
without the device acceptance evidence below.

## Process identity and ownership

Only the selected translated launch calls `JuiceSpawnForLaunch`; there is no
process-wide `posix_spawn` interposer. All preflight failures happen before
spawn. Once spawn succeeds, it returns success, even when later URL setup
fails. The launcher adopts the PID, process group, pipes and reaper before the
coordinator opens the external app.

In selected external-debug mode, `grape-trace-parent` uses `execve` instead of
spawning another Wine child. This fixes the previous assumption that attaching
to the helper also attached to Wine. The executable replacement preserves the
owned PID, group, stdin/stdout pipes and working directory. Ordinary launches
retain their existing spawn/ptrace-parent behavior. Wine rejects loss of debug
permission after exec rather than entering a legacy SIGSTOP handshake with no
tracing parent.

Every handoff callback checks the associated session object, child PID and
launch generation on the main owner queue. Stop and replacement revoke the
session before scheduling group termination. Normal reaping revokes it in the
same queue turn as `waitpid` and owner-state clearing. An unreaped child keeps
its numeric PID reserved; a delayed callback cannot authorize itself with
`kill(pid, 0)` or `CS_DEBUGGED` after ownership has been lost.

## Handoff and readiness

The only suppressed lifecycle Stop is `application-will-resign-active` for the
current pending handoff. The deadline is two minutes of continuous time,
including sleep and app suspension. A finite UIKit background task requests
cleanup on expiration; this does not grant unlimited iOS background execution.
The main-queue timer enforces the deadline when execution is available, and
normal Stop/replacement always cancels immediately.

URL acceptance permits attach polling. `CS_DEBUGGED` can permit one provisional
resume while Juice is foreground; it never declares the runtime ready. A Wine
acknowledgement is accepted only from the owned launch output, with matching
PID, generation and launch nonce, after Wine's arena-allocation/detach path
returns. An acknowledgement arriving before the URL completion is retained,
not lost. This is launch telemetry, not cryptographic authentication of an
external debugger script, and does not certify guest-code execution or app
compatibility.

The Wine overlay serializes allocation versus detach, rejects size overflow,
records exact RW/RX allocation pairs and prevalidates both views before freeing
either one. The inherited preallocated FEX arena and dual-map publication paths
remain in place. Full native Wine/FEX builds and physical executable-memory
validation are separate requirements.

## Automated checks

`bash scripts/test-jit-host.sh` executes the production transition logic under
ASan/UBSan, including 46,656 callback orderings, and runs native tests of the
actual helper's exec/default paths, PID preservation, cwd/argv handling and
failure exits. `scripts/verify-patch-stack.py` accepts only complete optional
prefixes, verifies all base layers and replays the full stack inside a temporary
copy. It never peels patches from live build inputs during verification.

These tests do not emulate UIKit scheduling, Mach VM, debugger attach, TXM,
cache coherency, Wine thread initialization or a real Windows workload.

## Required device evidence

Record exact device, OS, installation/signing method, StikDebug version/script
hash, Juice commit, Wine/FEX hashes and executable version/architecture. Verify
an attended foreground round trip; Stop before/after URL completion; replacement
launch; child exit and reaping at every phase; URL rejection; background task
expiration; lock/sleep beyond the deadline; actual executable publication and
cache invalidation; arena growth/recycling/exhaustion; TXM detach; repeated guest
thread creation; and clean process-group shutdown. Capture both successful and
failed logs, not just the host acknowledgement. Test the unselected native and
translated paths for regressions. No device certification is implied by green
host CI.
