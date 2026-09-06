import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import runtime_core_patchlib as patch
import juice_graphics_manifest as graphics


class PatchTests(unittest.TestCase):
    def setUp(self):
        self.fixture = (ROOT / "tests/runtime-bringup/fixtures/fex-reviewed-hunks.patch").read_text()
        self.edits = json.loads((ROOT / "scripts/runtime_core_fex_edits.json").read_text())
        self.additions = {"FEXCore/Source/Interface/Core/" + p.name: p.read_bytes()
                          for p in (ROOT / "patches/fex-runtime").glob("*.h")}

    def test_production_hunks_apply_and_reverse(self):
        revised = patch.revise_fex(self.fixture, self.edits, self.additions)
        original, expected = {}, {}
        # Fill absent context with distinguishable lines. Only captured original
        # hunks are real FEX code; this is a patch-application fixture, not FEX.
        for section in patch.sections(revised):
            path = patch.section_path(section)
            if path in self.additions:
                expected[path] = self.additions[path]
                continue
            _, hunks = patch.parse_hunks(section)
            old_lines, new_lines, offset = [], [], 0
            for header, before, after in hunks:
                start = int(header[1]) - 1
                gap = [f"// absent original line {i + 1}\n" for i in range(offset, start)]
                old_lines += gap + before
                new_lines += gap + after
                offset = start + len(before)
            original[path] = "".join(old_lines).encode()
            expected[path] = "".join(new_lines).encode()
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            for path, data in original.items():
                target = work / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            subprocess.run(["git", "init", "-q", str(work)], check=True)
            for args in (("--check",), (), ("--reverse", "--check")):
                subprocess.run(["git", "-C", str(work), "apply", *args, "-"],
                               input=revised.encode(), check=True, capture_output=True)
            for path, data in expected.items(): self.assertEqual((work / path).read_bytes(), data)
            subprocess.run(["git", "-C", str(work), "apply", "--reverse", "-"],
                           input=revised.encode(), check=True, capture_output=True)
            for path, data in original.items(): self.assertEqual((work / path).read_bytes(), data)
            for path in self.additions: self.assertFalse((work / path).exists())

    def test_unrelated_section_preserved(self):
        extra = patch.new_file_section("untouched.txt", b"keep exactly\n")
        revised = patch.revise_fex(self.fixture + extra, self.edits, self.additions)
        self.assertIn(extra, revised)

    def test_missing_section(self):
        with self.assertRaises(ValueError): patch.revise_fex(patch.sections(self.fixture)[0], self.edits, self.additions)

    def test_changed_reviewed_text(self):
        for edit in self.edits:
            damaged = self.fixture.replace("+" + edit["old"].splitlines()[0], "+unreviewed text", 1)
            with self.assertRaises(ValueError): patch.revise_fex(damaged, self.edits, self.additions)

    def test_duplicate_section(self):
        with self.assertRaises(ValueError): patch.revise_fex(self.fixture * 2, self.edits, self.additions)

    def test_repeated_update_rejected(self):
        revised = patch.revise_fex(self.fixture, self.edits, self.additions)
        with self.assertRaises(ValueError): patch.revise_fex(revised, self.edits, self.additions)

    def test_corrupt_hunk_counts(self):
        with self.assertRaises(ValueError): patch.revise_fex(self.fixture.replace("-325,6", "-325,7", 1), self.edits, self.additions)

    def test_unsafe_path(self):
        for path in ("../escape", "/absolute", "has space"):
            with self.assertRaises(ValueError): patch.new_file_section(path, b"text\n")

    def test_no_final_newline(self):
        with self.assertRaises(ValueError): patch.new_file_section("x", b"unterminated")

    def test_wine_source_patch_stay_identical(self):
        old, new = b"old Wine source\n", b"new Wine source\nsecond line\n"
        original = patch.new_file_section("dlls/wineios.drv/vulkan.m", old)
        revised = patch.revise_wine(original, {"dlls/wineios.drv/vulkan.m": (patch.blob_sha(old), new)},
                                    {"dlls/wineios.drv/graphics_layout.h": b"header\n"})
        output = {patch.section_path(s): patch.added_file(s) for s in patch.sections(revised)}
        self.assertEqual(output["dlls/wineios.drv/vulkan.m"], new)
        self.assertEqual(output["dlls/wineios.drv/graphics_layout.h"], b"header\n")

    def test_wine_changed_source_rejected(self):
        original = patch.new_file_section("vulkan.m", b"different\n")
        with self.assertRaises(ValueError): patch.revise_wine(original, {"vulkan.m": ("0" * 40, b"new\n")}, {})

    def test_existing_addition_rejected(self):
        original = patch.new_file_section("header.h", b"existing\n")
        with self.assertRaises(ValueError): patch.revise_wine(original, {}, {"header.h": b"new\n"})


class GraphicsManifestTests(unittest.TestCase):
    def setUp(self):
        self.manifest = (ROOT / "config/runtime-modules.txt").read_text()
        self.makefiles = graphics.load_reviewed(ROOT, True)

    def test_pinned_module_declarations(self):
        report = graphics.validate(self.manifest, self.makefiles)
        self.assertEqual(report["selected_graphics_modules"], 14)
        self.assertFalse(report["renderer_certified"])
        self.assertEqual(len(report["optional_pe_libraries"]), 3)

    def test_every_new_module_required(self):
        for name in graphics.GRAPHICS_MODULES:
            with self.subTest(name=name), self.assertRaises(ValueError):
                graphics.validate(self.manifest.replace(f"dlls/{name}/aarch64-windows/{name}.dll\n", ""), self.makefiles)

    def test_compiler_alias_dependency(self):
        with self.assertRaises(ValueError):
            graphics.validate(self.manifest.replace("dlls/d3dcompiler_47/aarch64-windows/d3dcompiler_47.dll\n", ""), self.makefiles)

    def test_missing_dependency(self):
        with self.assertRaises(ValueError): graphics.validate(self.manifest.replace("dlls/wined3d/aarch64-windows/wined3d.dll\n", ""), self.makefiles)

    def test_static_import_not_a_dll(self):
        del self.makefiles["wine/libs/uuid/Makefile.in"]
        with self.assertRaises(ValueError): graphics.validate(self.manifest, self.makefiles)

    def test_new_unix_library_requires_integration(self):
        self.makefiles["wine/dlls/d3d9/Makefile.in"] += "UNIXLIB = new.so\n"
        with self.assertRaises(ValueError): graphics.validate(self.manifest, self.makefiles)

    def test_invalid_manifest(self):
        for invalid in ("../file", "dlls/a/aarch64-windows/../a.dll", "not a target"):
            with self.assertRaises(ValueError): graphics.validate(self.manifest + invalid + "\n", self.makefiles)

    def test_duplicate_case_insensitive_name(self):
        with self.assertRaises(ValueError): graphics.validate(self.manifest + "dlls/D3D9/aarch64-windows/D3D9.dll\n", self.makefiles)

    def test_variable_requires_review(self):
        self.makefiles["wine/dlls/d3d9/Makefile.in"] += "IMPORTS += $(SURPRISE)\n"
        with self.assertRaises(ValueError): graphics.validate(self.manifest, self.makefiles)

    def test_module_name_mismatch(self):
        self.makefiles["wine/dlls/d3d9/Makefile.in"] = "MODULE = other.dll\n"
        with self.assertRaises(ValueError): graphics.validate(self.manifest, self.makefiles)

    def test_make_continuations_and_operators(self):
        fields = graphics.assignments("IMPORTS = a \\\n b # comment\nIMPORTS += c\nIMPORTS ?= ignored\n")
        self.assertEqual(fields["IMPORTS"].split(), ["a", "b", "c"])

    def test_oversized_makefile(self):
        with self.assertRaises(ValueError): graphics.assignments("x" * 65537)


if __name__ == "__main__":
    unittest.main()
