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


if __name__ == "__main__":
    unittest.main()
