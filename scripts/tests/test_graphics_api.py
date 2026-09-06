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

    def arm64ec_fixture(self):
        # Structural test data only, not an executable runtime replacement.
        data = bytearray(1024)
        data[:2] = b"MZ"
        struct.pack_into("<I", data, 60, 128)
        data[128:132] = b"PE\0\0"
        struct.pack_into("<HH", data, 132, 0x8664, 1)
        struct.pack_into("<HH", data, 148, 240, 0x2000)
        struct.pack_into("<H", data, 152, 0x20B)
        struct.pack_into("<Q", data, 152 + 24, 0x180000000)
        struct.pack_into("<II", data, 152 + 56, 0x2000, 512)
        struct.pack_into("<I", data, 152 + 108, 16)
        struct.pack_into("<II", data, 152 + 112 + 80, 0x1000, 208)
        data[392:400] = b".rdata\0\0"
        struct.pack_into("<IIII", data, 400, 512, 0x1000, 512, 512)
        struct.pack_into("<I", data, 512, 208)
        struct.pack_into("<Q", data, 512 + 200, 0x180001100)
        struct.pack_into("<III", data, 768, 1, 0x1120, 1)
        struct.pack_into("<II", data, 800, 0x1001, 4)
        return data

    def inspect_ec(self, data):
        (self.root / "ec.dll").write_bytes(data)
        return api.inspect_build(self.root, ["ec.dll"], "arm64ec")[0]

    def test_arm64ec_linked_header_and_metadata_versions(self):
        for version in (1, 2):
            with self.subTest(version=version):
                data = self.arm64ec_fixture()
                struct.pack_into("<I", data, 768, version)
                report = self.inspect_ec(data)
                self.assertEqual(report["machine"], 0x8664)
                self.assertEqual(report["architecture"], "arm64ec")
                self.assertEqual(report["chpe_metadata"], {"version": version, "code_map_entries": 1})
                self.assertEqual(report["bytes"], len(data))

    def test_arm64ec_does_not_accept_object_machine_or_native_arm64(self):
        for machine in (0xA641, 0xAA64, 0x14C, 0xA64E):
            with self.subTest(machine=machine):
                data = self.arm64ec_fixture()
                struct.pack_into("<H", data, 132, machine)
                with self.assertRaises(api.AuditError): self.inspect_ec(data)

    def test_arm64ec_rejects_ordinary_x64(self):
        for field, fmt, value in ((152 + 112 + 80, "<II", (0, 0)),
                                  (512 + 200, "<Q", (0,))):
            data = self.arm64ec_fixture()
            struct.pack_into(fmt, data, field, *value)
            with self.assertRaises(api.AuditError): self.inspect_ec(data)

    def test_arm64ec_metadata_bounds(self):
        mutations = (
            (134, "<H", 97), (148, "<H", 199), (152, "<H", 0x10B),
            (152 + 108, "<I", 10), (152 + 108, "<I", 0xFFFFFFFF),
            (152 + 56, "<I", 1024), (152 + 60, "<I", 1025),
            (152 + 112 + 84, "<I", 207), (152 + 112 + 84, "<I", 4097),
            (512, "<I", 207), (512, "<I", 209),
            (512 + 200, "<Q", 0x17FFFFFFF), (512 + 200, "<Q", 0x180003000),
            (768, "<I", 0), (768, "<I", 3), (772, "<I", 0),
            (772, "<I", 0x11FC), (776, "<I", 1024 * 1024 + 1),
            (408, "<I", 1024), (412, "<I", 1024),
        )
        for offset, fmt, value in mutations:
            with self.subTest(offset=offset, value=value):
                data = self.arm64ec_fixture()
                struct.pack_into(fmt, data, offset, value)
                with self.assertRaises(api.AuditError): self.inspect_ec(data)

    def test_arm64ec_ambiguous_rva_rejected(self):
        data = self.arm64ec_fixture()
        struct.pack_into("<H", data, 134, 2)
        data[432:472] = data[392:432]
        with self.assertRaises(api.AuditError): self.inspect_ec(data)

    def test_arm64ec_all_file_truncations_rejected(self):
        data = self.arm64ec_fixture()
        for size in range(len(data)):
            with self.subTest(size=size):
                with self.assertRaises(api.AuditError): self.inspect_ec(data[:size])

    def test_arm64ec_metadata_with_no_code_ranges(self):
        data = self.arm64ec_fixture()
        struct.pack_into("<II", data, 772, 0, 0)
        self.assertEqual(self.inspect_ec(data)["chpe_metadata"]["code_map_entries"], 0)

if __name__ == "__main__": unittest.main()
