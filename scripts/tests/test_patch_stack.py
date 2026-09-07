#!/usr/bin/env python3
"""Regression tests for the production isolated patch verifier."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "verify-patch-stack.py"
spec = importlib.util.spec_from_file_location("patch_stack", SCRIPT)
stack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stack)


class PatchStackTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        root = Path(self.work.name)
        self.source = root / "source"
        self.source.mkdir()
        self.base = root / "base.patch"
        self.overlay = root / "overlay.patch"
        self.lines = [f"line {i}\n" for i in range(24)]
        self.base.write_text("diff --git a/driver.c b/driver.c\nnew file mode 100644\n"
                             "--- /dev/null\n+++ b/driver.c\n@@ -0,0 +1,24 @@\n" +
                             "".join("+" + line for line in self.lines))
        self.overlay.write_text("diff --git a/driver.c b/driver.c\n--- a/driver.c\n+++ b/driver.c\n"
                                "@@ -10,3 +10,3 @@\n line 9\n-line 10\n+fixed 10\n line 11\n")
        self.lines[10] = "fixed 10\n"
        (self.source / "driver.c").write_text("".join(self.lines))
        (self.source / "unrelated").write_text("do not touch\n")

    def snapshot(self):
        return {p.name: (p.read_bytes(), p.stat().st_mode) for p in self.source.iterdir() if p.is_file()}

    def test_repeatable_and_read_only(self):
        before = self.snapshot()
        for _ in range(2):
            stack.verify_stack(self.source, [self.base, self.overlay])
            self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.source / ".git").exists())

    def test_optional_layer_absent_and_present(self):
        before = self.snapshot()
        self.assertEqual(stack.verify_stack(self.source, [self.base], [self.overlay]), 1)
        self.assertEqual(self.snapshot(), before)
        self.lines[10] = "line 10\n"
        (self.source / "driver.c").write_text("".join(self.lines))
        before = self.snapshot()
        self.assertEqual(stack.verify_stack(self.source, [self.base], [self.overlay]), 0)
        self.assertEqual(self.snapshot(), before)

    def test_optional_drift_is_not_mistaken_for_absent(self):
        self.lines[10] = "broken optional implementation\n"
        (self.source / "driver.c").write_text("".join(self.lines))
        before = self.snapshot()
        with self.assertRaises(subprocess.CalledProcessError):
            stack.verify_stack(self.source, [self.base], [self.overlay])
        self.assertEqual(self.snapshot(), before)

    def test_optional_stack_is_replayed_even_when_absent(self):
        self.lines[10] = "line 10\n"
        (self.source / "driver.c").write_text("".join(self.lines))
        self.overlay.write_text(self.overlay.read_text().replace("-line 10", "-unknown base"))
        with self.assertRaises(subprocess.CalledProcessError):
            stack.verify_stack(self.source, [self.base], [self.overlay])

    def test_unrecorded_drift_outside_overlay_is_rejected(self):
        self.lines[0] = "unrecorded source drift\n"
        (self.source / "driver.c").write_text("".join(self.lines))
        before = self.snapshot()
        with self.assertRaises(subprocess.CalledProcessError):
            stack.verify_stack(self.source, [self.base, self.overlay])
        self.assertEqual(self.snapshot(), before)

    def test_overlay_mismatch_is_read_only(self):
        self.lines[10] = "different implementation\n"
        (self.source / "driver.c").write_text("".join(self.lines))
        before = self.snapshot()
        with self.assertRaises(subprocess.CalledProcessError):
            stack.verify_stack(self.source, [self.base, self.overlay])
        self.assertEqual(self.snapshot(), before)

    def test_layer_order_matters(self):
        with self.assertRaises(subprocess.CalledProcessError):
            stack.verify_stack(self.source, [self.overlay, self.base])

    def test_unsafe_path_is_rejected(self):
        self.overlay.write_text("diff --git a/../outside b/../outside\n")
        with self.assertRaises(ValueError):
            stack.verify_stack(self.source, [self.base, self.overlay])

    def test_symlink_is_rejected(self):
        target = self.source / "driver.c"
        target.unlink()
        target.symlink_to(self.base)
        with self.assertRaises(ValueError):
            stack.verify_stack(self.source, [self.base, self.overlay])
        self.assertTrue(target.is_symlink())

    def test_empty_patch_is_rejected(self):
        self.overlay.write_text("")
        with self.assertRaises(ValueError):
            stack.verify_stack(self.source, [self.base, self.overlay])


class RepositoryWineStackTests(unittest.TestCase):
    """Exercise the actual shipped stack, not just synthetic patch fixtures."""

    def test_all_incremental_prefixes_and_pointer_sized_abi(self):
        root = SCRIPT.parent.parent
        base = [root / "patches" / name for name in (
            "wine-ios.patch", "wine-ios-runtime-hardening.patch", "wine-ios-graphics.patch")]
        optional = [root / "patches" / name for name in (
            "wine-stikdebug-jit.patch", "wine-stikdebug-lifecycle.patch",
            "wine-stikdebug-handoff.patch", "wine-stikdebug-abi.patch",
            "wine-ios-embedded.patch")]
        paths = set().union(*(stack.patch_paths(patch) for patch in base + optional))
        source = root / "wine"
        before = {path: (source / path).read_bytes() for path in paths if (source / path).is_file()}
        with tempfile.TemporaryDirectory() as directory:
            isolated = Path(directory)
            stack.copy_sources(source, isolated, paths)
            subprocess.run(["git", "init", "-q", str(isolated)], check=True)
            command = ["git", "-C", str(isolated), "apply", "--recount"]
            applied = stack.verify_stack(isolated, base, optional, quiet=True)
            for patch in reversed(optional[:applied]):
                subprocess.run(command + ["--reverse", str(patch)], check=True, capture_output=True)
            for count in range(len(optional) + 1):
                with self.subTest(applied=count):
                    self.assertEqual(stack.verify_stack(isolated, base, optional, quiet=True), count)
                if count < len(optional):
                    subprocess.run(command + [str(optional[count])], check=True, capture_output=True)
            spec = isolated / "dlls/ntdll/ntdll.spec"
            text = spec.read_text()
            for name in ("NtWineAllocateJitMemory", "NtWineFreeJitMemory"):
                self.assertIn(f"@ stdcall -private -syscall -arch=win64 {name}(ptr ptr ptr)", text)
            self.assertIn("NtWineDetachJitDebugger()", text)
            arm64ec = (isolated / "dlls/ntdll/signal_arm64ec.c").read_text()
            self.assertIn("DEFINE_SYSCALL(NtWineAllocateJitMemory,", arm64ec)
            self.assertIn("DEFINE_SYSCALL(NtWineFreeJitMemory,", arm64ec)
            self.assertIn("DEFINE_SYSCALL(NtWineDetachJitDebugger,", arm64ec)
            # A partial/incorrect ABI overlay must still fail, not be mistaken
            # for an unapplied stack or accepted by weakening the verifier.
            spec.write_text(text.replace("NtWineAllocateJitMemory(ptr ptr ptr)",
                                         "NtWineAllocateJitMemory(ptr int64)"))
            with self.assertRaises(subprocess.CalledProcessError):
                stack.verify_stack(isolated, base, optional, quiet=True)
        after = {path: (source / path).read_bytes() for path in paths if (source / path).is_file()}
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
