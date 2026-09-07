import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("sidestore_package", Path(__file__).parents[1] / "sidestore_package.py")
api = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(api)


class SideStorePackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    @staticmethod
    def image(install_name="@loader_path/old.dylib", dependency="/usr/lib/libSystem.B.dylib"):
        # Structural fixtures only. They are not executable replacements and
        # are never copied into an application artifact.
        def dylib(kind, name):
            raw = name.encode() + b"\0"
            size = (24 + len(raw) + 7) & ~7
            return struct.pack("<6I", kind, size, 24, 0, 0, 0) + raw + bytes(size - 24 - len(raw))
        segment = bytearray(152)
        struct.pack_into("<II", segment, 0, 0x19, len(segment))
        segment[8:14] = b"__TEXT"
        struct.pack_into("<QQQQ", segment, 24, 0, 4096, 0, 4096)
        struct.pack_into("<IIII", segment, 56, 5, 5, 1, 0)
        segment[72:78] = b"__text"
        struct.pack_into("<QQI", segment, 104, 2048, 8, 2048)
        struct.pack_into("<I", segment, 136, 0x80000400)
        commands = bytes(segment) + dylib(0xD, install_name) + dylib(0xC, dependency)
        data = bytearray(4096)
        data[:32] = struct.pack("<8I", api.MAGIC, api.ARM64, 0, 6, 3, len(commands), 0, 0)
        data[32:32 + len(commands)] = commands
        data[2048:2056] = b"FAKECODE"
        return data

    @staticmethod
    def pe(alignment=16384, code=True):
        data = bytearray(1024)
        data[:2] = b"MZ"
        struct.pack_into("<I", data, 60, 128)
        data[128:132] = b"PE\0\0"
        struct.pack_into("<HH", data, 132, 0xAA64, 1)
        struct.pack_into("<H", data, 148, 240)
        struct.pack_into("<H", data, 152, 0x20B)
        struct.pack_into("<I", data, 184, alignment)
        struct.pack_into("<I", data, 404, alignment)
        struct.pack_into("<I", data, 428, 0x60000020 if code else 0x40000040)
        return data

    def test_framework_load_command_rewrite_preserves_code(self):
        path = self.root / "runtime"
        path.write_bytes(self.image())
        before = path.read_bytes()[2048:]
        api.rewrite_framework(path, "JuiceNTDLL", {})
        data = path.read_bytes()
        self.assertEqual(data[2048:], before)
        _, commands, first_data = api.macho(data)
        self.assertEqual(first_data, 2048)
        strings = [api.command_string(command) for kind, command in commands if kind in api.DYLIB_COMMANDS]
        self.assertEqual(strings, ["@rpath/JuiceNTDLL.framework/JuiceNTDLL", "/usr/lib/libSystem.B.dylib"])

    def test_framework_dependency_rewrite(self):
        path = self.root / "runtime"
        path.write_bytes(self.image(dependency="@loader_path/libgnutls.30.dylib"))
        api.rewrite_framework(path, "JuiceSecurity", {"libgnutls.30.dylib": "JuiceGnuTLS"})
        commands = api.macho(path.read_bytes())[1]
        self.assertIn("@rpath/JuiceGnuTLS.framework/JuiceGnuTLS",
                      [api.command_string(c) for k, c in commands if k in api.DYLIB_COMMANDS])

    def test_unknown_dependency_rejected_without_writing(self):
        path = self.root / "runtime"
        data = self.image(dependency="/var/jb/usr/lib/unknown.dylib")
        path.write_bytes(data)
        with self.assertRaises(api.PackageError): api.rewrite_framework(path, "JuiceSecurity", {})
        self.assertEqual(path.read_bytes(), data)

    def test_macho_truncations_and_bounds(self):
        original = self.image()
        for size in (0, 4, 31, 32, 100, 1024, 4095):
            with self.subTest(size=size), self.assertRaises(api.PackageError): api.macho(original[:size])
        for offset, value in ((4, 7), (12, 1), (16, 5000), (20, 4 * 1024 * 1024 + 1),
                              (36, 7), (96, 1000)):
            data = self.image(); struct.pack_into("<I", data, offset, value)
            with self.subTest(offset=offset), self.assertRaises(api.PackageError): api.macho(data)

    def test_pe_page_alignment(self):
        path = self.root / "test.dll"
        path.write_bytes(self.pe()); api.pe_audit(path)
        path.write_bytes(self.pe(4096, code=False)); api.pe_audit(path)
        path.write_bytes(self.pe(4096))
        with self.assertRaises(api.PackageError): api.pe_audit(path)
        data = self.pe(); struct.pack_into("<I", data, 404, 4096); path.write_bytes(data)
        with self.assertRaises(api.PackageError): api.pe_audit(path)

    def test_pe_wrong_machine(self):
        path = self.root / "test.dll"
        for machine in (0x14C, 0, 0x1C4):
            data = self.pe(); struct.pack_into("<H", data, 132, machine); path.write_bytes(data)
            with self.subTest(machine=machine), self.assertRaises(api.PackageError): api.pe_audit(path)

    def test_side_store_entitlements_are_minimal(self):
        root = Path(__file__).resolve().parents[2]
        self.assertEqual(plistlib.loads((root / "config/sidestore-entitlements.plist").read_bytes()), {"get-task-allow": True})

    def test_incomplete_app_not_advertised_as_embedded(self):
        app = self.root / "Juice.app"; app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Juice"}))
        with self.assertRaises(api.PackageError): api.audit_app(app)


if __name__ == "__main__": unittest.main()
