import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("graphics_api", Path(__file__).parents[1] / "verify_graphics_api.py")
api = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(api)

class GraphicsAPITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.write("config/runtime-modules.txt", "dlls/demo/aarch64-windows/demo.dll\ndlls/dependency/aarch64-windows/dependency.dll\n")
        self.write("config/graphics-api-modules.txt", "demo\n")
        self.write("wine/dlls/demo/Makefile.in", "MODULE = demo.dll\nIMPORTS = dependency $(PNG_PE_LIBS) uuid\n")
        self.write("wine/dlls/dependency/Makefile.in", "MODULE = dependency.dll\n")
        self.write("wine/dlls/demo/demo.spec", "@ stdcall Available()\n@ stub Unimplemented\n")

    def write(self, name, text):
        p = self.root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def test_literal_imports_and_configured_features(self):
        report = api.audit(self.root)
        self.assertEqual(report["packaged_count"], 2)
        self.assertEqual(report["modules"][0]["imports"], ["dependency.dll"])
        self.assertEqual(report["modules"][0]["configured_import_expressions"], ["$(PNG_PE_LIBS)"])
        self.assertEqual(report["modules"][0]["declared_stub_exports"], 1)

    def test_missing_import(self):
        self.write("config/runtime-modules.txt", "dlls/demo/aarch64-windows/demo.dll\n")
        with self.assertRaisesRegex(api.AuditError, "not packaged"):
            api.audit(self.root)

    def test_missing_source(self):
        (self.root / "wine/dlls/demo/Makefile.in").unlink()
        with self.assertRaisesRegex(api.AuditError, "no source module"):
            api.audit(self.root)

    def test_wrong_module(self):
        self.write("wine/dlls/demo/Makefile.in", "MODULE = unrelated.dll\n")
        with self.assertRaises(api.AuditError): api.audit(self.root)

    def test_case_collisions(self):
        with (self.root / "config/runtime-modules.txt").open("a") as file:
            file.write("dlls/other/aarch64-windows/DEMO.dll\n")
        with self.assertRaisesRegex(api.AuditError, "case-colliding"): api.audit(self.root)

    def test_path_traversal(self):
        self.write("config/graphics-api-modules.txt", "../outside\n")
        with self.assertRaises(api.AuditError): api.audit(self.root)

    def test_duplicate_catalog(self):
        self.write("config/graphics-api-modules.txt", "demo\ndemo\n")
        with self.assertRaises(api.AuditError): api.audit(self.root)

    def test_nul(self):
        self.write("wine/dlls/demo/Makefile.in", "MODULE=demo.dll\0")
        with self.assertRaises(api.AuditError): api.audit(self.root)

    def test_bound(self):
        self.write("config/graphics-api-modules.txt", "#" * (1024 * 1024 + 1))
        with self.assertRaises(api.AuditError): api.audit(self.root)

    def test_continuation_and_append(self):
        parsed = api.assignments("IMPORTS = one \\\n two\nIMPORTS += three # comment\n")
        self.assertEqual(parsed["IMPORTS"].split(), ["one", "two", "three"])

    def test_no_shell_evaluation(self):
        self.write("wine/dlls/demo/Makefile.in", "MODULE=demo.dll\nIMPORTS=$(shell echo injected)\n")
        with self.assertRaises(api.AuditError): api.audit(self.root)

    def test_targets(self):
        report = api.audit(self.root)
        self.assertEqual(api.make_targets(report, "dlls/demo/aarch64-windows/demo.dll: dependency\n", "aarch64"),
                         ["dlls/demo/aarch64-windows/demo.dll"])
        with self.assertRaises(api.AuditError): api.make_targets(report, "", "aarch64")
        with self.assertRaises(api.AuditError): api.make_targets(report, "", "riscv64")

    def test_ambiguous_arm64ec_target(self):
        makefile = "dlls/demo/aarch64-windows/demo.dll:\ndlls/demo/arm64ec-windows/demo.dll:\n"
        with self.assertRaises(api.AuditError): api.make_targets(api.audit(self.root), makefile, "arm64ec")

    def test_built_image_and_wrong_arch(self):
        data = bytearray(256)
        data[:2] = b"MZ"
        struct.pack_into("<I", data, 60, 128)
        data[128:132] = b"PE\0\0"
        struct.pack_into("<H", data, 132, 0xAA64)
        struct.pack_into("<H", data, 150, 0x2000)
        (self.root / "demo.dll").write_bytes(data)
        out = api.inspect_build(self.root, ["demo.dll"], "aarch64")
        self.assertEqual(out[0]["bytes"], 256)
        self.assertEqual(len(out[0]["sha256"]), 64)
        with self.assertRaises(api.AuditError): api.inspect_build(self.root, ["demo.dll"], "i386")
        data[150:152] = b"\0\0"
        (self.root / "demo.dll").write_bytes(data)
        with self.assertRaises(api.AuditError): api.inspect_build(self.root, ["demo.dll"], "aarch64")

    def test_truncated_image(self):
        (self.root / "demo.dll").write_bytes(b"MZ")
        with self.assertRaises(api.AuditError): api.inspect_build(self.root, ["demo.dll"], "aarch64")

if __name__ == "__main__": unittest.main()
