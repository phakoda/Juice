# Compatibility bring-up

This feature layer focuses on safely widening application coverage without claiming universal Wine parity.

## Included

- Versioned per-executable profiles (maximum 128) with saved arguments, validated working directories, bounded Wine DLL overrides, quieter logs, isolated prefixes, and an opt-in StikDebug JIT selector for translated applications.
- Isolated prefixes are cloned from the currently prepared runtime prefix, retain their own Wine state, refresh runtime symlinks on launch, and never silently fall back to the shared prefix if creation fails.
- Structural PE preflight before wineserver spawn for x86, x86-64, ARM64, ARM64EC and ARM64X executables; rejects DLLs/non-GUI-console images and missing runtime helpers/modules.
- UTF-8 streaming output hardening that preserves partial scalars across bounded flushes and replaces malformed bytes without splitting valid text.
- A bounded evidence validator/report generator for compatibility and performance runs, with separate cold/warm/sustained measurements and median/p95 summaries.
- Sanitizer-backed portable regressions plus real iPhoneOS app and launcher compilation in CI.

## What this does not promise

A passing preflight is not a compatibility guarantee. Application dependencies, Direct3D/Vulkan feature levels, DRM/anti-cheat, kernel drivers, COM/.NET installers, audio edge cases and third-party JIT availability still require workload testing. iOS executable-memory and process-lifecycle constraints also differ from macOS/Linux.

## Device acceptance matrix

For each device/OS/runtime commit, record native ARM64, x64 and x86/WoW64 tests covering: clean prefix boot; EXE and portable ZIP launch; MSI/installer flows; file open/save; networking/TLS; keyboard/mouse/controller input; multi-window; graphics resize/surface recovery; audio; app switching/lock/unlock; repeated Stop/relaunch; memory pressure; JIT attach/detach where enabled; and sustained thermals/performance.

Use `scripts/juice_runtime_evidence.py` to validate and summarize captured JSON records. Do not mix failed runs into successful-run latency summaries and do not compare different devices/resolutions as if they were the same benchmark.
